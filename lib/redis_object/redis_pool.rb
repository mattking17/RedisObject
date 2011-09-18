module Seabright
  class RedisPool
    
    class << self
      
      POOL_SIZE = 1
      
      def connection
        @connections ||= []
        return @connections[(nxt = next_idx)] if @connections[nxt] and @connections[nxt].connected?
        @connections[nxt] ||= File.exists?("/tmp/redis.sock") ? Redis.new(:path => "/tmp/redis.sock") : Redis.new rescue Redis.new
      end
      
      def next_idx
        @idx = @idx && @idx < POOL_SIZE-1 ? @idx+1 : 1
      end
      
    end
    
  end
end