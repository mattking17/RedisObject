module Seabright
  class RedisObject
    require "redis"
    require "yajl"
    require "activesupport"
    require "redis_object/redis_pool"
    require "redis_object/collection"
    include AbstractController::Callbacks

    @@indices = []
    @@sort_indices = [:created_at,:updated_at]
    @@field_formats = {
      :created_at => :format_date,
      :updated_at => :format_date
    }
    @@time_irrelevant = false
    
    def initialize(ident, prnt = nil)
      if prnt && prnt.class != String
        @parent = prnt
        @parent_id = prnt.hkey
      else
        @parent_id = prnt
      end
      @collections = {}
      if ident && ident.class == String
        load(ident)
      elsif ident && ident.class == Hash
        if load(ident[id_sym])
          @data = ident
        end
      end
      # enforce_formats
    end
    
    def save_history?
      save_history || self.class.save_history?
    end
    
    def dump(prnt=nil)
      require "utf8_utils"
      out = ["puts \"Creating: #{id}\""]
      s_id = (prnt ? "#{prnt.id} #{id}" : id).gsub(/\W/,"_")
      out << "a#{s_id} = #{self.class.name}.new(#{actual.to_s.tidy_bytes},#{prnt.id})"
      @collections.each do |col|
        col.each do |sobj|
          out << sobj.dump(self)
        end
      end
      out << "a#{prnt.id.gsub(/\W/,"_")} << a#{s_id}" if prnt
      out << "a#{s_id}.save"
      out.join("\n")
    end
    
    def store_image
      redis.sadd history_key, {:timestamp => Time.now, :snapshot => actual}.to_json
    end
    
    def actual
      raw #.inject({}) {|acc,(k,v)| acc[k] = v if ![:collections, :key].include?(k) && (!@data[:collections] || !@data[:collections].include?(k.to_s)); acc }
    end
    
    def to_json
      Yajl::Encoder.encode(actual)
    end
    
    def enforce_format(k,v)
      v && @@field_formats[k.to_sym] ? send(@@field_formats[k.to_sym],v) : v
    end
    
    def format_date(val)
      val.instance_of?(DateTime) ? val : DateTime.parse(val)
    end
    
    def format_number(val)
      val.to_i
    end
    
    def key(ident = id, prnt = parent)
      "#{prnt ? prnt.class==String ? "#{prnt}:" : "#{prnt.key}:" : ""}#{self.class.name}:#{ident.gsub(/^.*:/,'')}"
    end
    
    def hkey(ident = nil, prnt = nil)
      "#{key}_h"
    end
    
    def history_key(ident = nil, prnt = nil)
      "#{key}_history"
    end
    
    def hkey_col(ident = nil, prnt = nil)
      "#{hkey}:collections"
    end
    
    def parent
      @parent ||= @parent_id ? find_by_key(@parent_id) : nil
    end
    
    def parent=(obj)
      @parent = obj.class == String ? self.find_by_key(obj) : obj
      if @parent
        @parent_id = obj.hkey
        set(:parent, @parent_id)
      end
    end
    
    def id
      @id || set(:id_sym, get(:id_sym) || ActiveSupport::SecureRandom.hex(8))
    end
    
    def load(id)
      @id = id
      redis.smembers(hkey_col).each do |name|
        @collections[name] = Seabright::Collection.load(name,self)
      end
      true
    end
    
    def save
      set(:class, self.class.name)
      set(id_sym,id)
      set(:key, key)
      if @data
        saving = @data
        @data = false
        saving.each do |k,v|
          set(k,v)
        end
      end
      update_timestamps
      redis.sadd(self.class.name.pluralize, key)
      @collections.each do |k,col|
        col.save
      end
      save_indices
    end
    
    def save_indices
      @@indices.each do |indx|
        indx.each do |key,idx|
          
        end
      end
      @@sort_indices.each do |idx|
        redis.zadd(index_key(idx), send(idx).to_i, hkey)
      end
    end
    
    def index_key(idx,extra=nil)
      "#{parent ? "#{parent.key}:" : ""}#{self.class.name.pluralize}::#{idx}#{extra ? ":#extra" : ""}"
    end
    
    def delete!
      redis.del key
      redis.srem(self.class.name.pluralize, key)
    end
    
    def <<(obj)
      obj.parent = self
      obj.save
      name = obj.class.name.downcase.pluralize.to_sym
      redis.sadd hkey_col, name
      @collections[name] ||= Seabright::Collection.load(name,self)
      @collections[name] << obj.hkey
    end
    alias_method :push, :<<
    
    def reference(obj)
      name = obj.class.name.downcase.pluralize.to_sym
      redis.sadd hkey_col, name
      @collections[name] ||= Seabright::Collection.load(name,self)
      @collections[name] << obj.hkey
    end
    
    def raw
      redis.hgetall(hkey).inspect
    end
    
    def get(k)
      if @collections[k.to_s] 
        get_collection(k.to_s)
      else
        val = @data ? @data[k] : redis.hget(hkey, k.to_s)
        enforce_format(k,val)
      end
    end
    alias_method :[], :get
    
    def get_collection(name)
      @collections[name.to_s] ||= Seabright::Collection.load(name,self)
    end
    
    def set(k,v)
      @data ? @data[k] = v : @collections[k.to_sym] ? get_collection(k).replace(v) : redis.hset(hkey, k.to_s.gsub(/\=$/,''), v)
      v
    end
    
    private
    
    def redis
      @@redis ||= self.class.redis
    end
    
    def method_missing(sym, *args, &block)
      sym.to_s =~ /=$/ ? set(sym,*args) : get(sym)
    end
    
    def id_sym(cls=nil)
      "#{(cls || self.class.name).downcase}_id".to_sym
    end
    
    def update_timestamps
      return if @@time_irrelevant
      set(:created_at, Time.now) if !get(:created_at)
      set(:updated_at, Time.now)
    end
    
    class << self
      
      def indexed(index,num=5,reverse=false)
        out = []
        redis.send(reverse ? :zrevrange : :zrange, "#{self.name.pluralize}::#{index}", 0, num).each do |member|
          if a = self.find_by_key(member)
            out << a
          else
            # redis.zrem(self.name.pluralize,member)
          end
        end
        out
      end
      
      def recently_created(num=5)
        self.indexed(:created_at,num,true)
      end
      
      def recently_updated(num=5)
        self.indexed(:updated_at,num,true)
      end
      
      def all
        out = []
        redis.smembers(self.name.pluralize).each do |member|
          if a = self.find(member)
            out << a
          else
            redis.srem(self.name.pluralize,member)
          end
        end
        out
      end
      
      def find(ident,prnt=nil)
        redis.exists(self.hkey(ident,prnt)) ? self.new(ident,prnt) : nil
      end
      
      def create(ident)
        obj = self.class.new(ident)
        obj.save
        obj
      end
      
      def dump
        out = []
        self.all.each do |obj|
          out << obj.dump
        end
        out.join("\n")
      end
      
      def index(opts)
        @@indices << opts
      end
      
      def time_matters_not!
        @@time_irrelevant = true
        @@sort_indices.delete(:created_at)
        @@sort_indices.delete(:updated_at)
      end
      
      def sort_by(k)
        @@sort_indices << (k)
      end
      
      def date(k)
        @@field_formats[k] = :format_date
      end
      
      def number(k)
        @@field_formats[k] = :format_number
      end
      
      def save_history!(v=true)
        @@save_history = v
      end
      
      def save_history?
        @@save_history || false
      end
      
      def key(ident, prnt = nil)
        "#{prnt ? prnt.class==String ? "#{prnt}:" : "#{prnt.key}:" : ""}#{self.name}:#{ident.gsub(/^.*:/,'')}"
      end
      
      def hkey(ident = id, prnt = nil)
        "#{key(ident,prnt)}_h"
      end
      
      def history_key(ident = id, prnt = nil)
        "#{key(ident,prnt)}_history"
      end
      
      def hkey_col(ident = id, prnt = nil)
        "#{hkey(ident,prnt)}:collections"
      end
      
      def find_by_key(k)
        if cls = redis.hget(k,:class) 
          o_id = redis.hget(k,id_sym(cls))
          prnt = redis.hget(k,:parent)
          puts "Key: #{cls}:#{o_id}_h"
          if redis.exists(k)
            puts "Exists!"
            return Object.const_get(cls.to_sym).new(o_id,prnt)
          end
        end
        nil
      end
      
      def save_all
        all.each do |obj|
          obj.save
        end
        true
      end
      
      def redis
        @@redis ||= Seabright::RedisPool.connection
      end
      
      def id_sym(cls=nil)
        "#{(cls || self.name).downcase}_id".to_sym
      end
      
    end
    
  end
end