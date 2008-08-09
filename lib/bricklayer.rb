unless Hash.method_defined?(:stringify_keys!)
  class Hash
    def stringify_keys!
      keys.each do |key|
        self[key.to_s] = delete(key)
      end
      self
    end
  end
end

module Bricklayer
  class Base
    class << self
      @@state = {}
      @@last_child = nil
      
      def authenticate(u,p)
        state[:auth] = [u, p]
      end
      
      def inherited(subclass)
        @@last_child = subclass
        @@state[@@last_child] ||= {}
        state[:remote_methods] ||= {}
      end
      
      def state
        raise "invalid `state' call. Missing descendant information" unless @@last_child
        @@state[@@last_child]
      end
      
      def service_url url, opts = {}
        state[:last_service_url] = [url, opts]
      end
      
      def remote_method(method_name, opts = {}, &response_callback)
        raise "You must provide at least one service url before defining a remote method" unless state[:last_service_url]
        lsu = state[:last_service_url]
        rem_meth_params = {
          :method_name => method_name,
          :service_url => lsu[0],
          :default_parameter_stack => [(lsu[1][:default_parameters] || {}), (opts.delete(:default_parameters) || {})],
          :override_parameter_stack => [(opts.delete(:override_parameters) || {}), (lsu[1][:override_parameters] || {})],
          :request_method => (opts.delete(:request_method) || lsu[1][:request_method] || :get),
          :wants => (opts.delete(:wants) || lsu[1][:wants] || :body),
          :response_callback => response_callback,
          :required_parameters => (opts.delete(:required_parameters) || [])
        }
        state[:remote_methods][method_name] = RemoteMethod.new(rem_meth_params)
        
        self.class_eval <<-EOM
          def #{method_name}(args = {}, &block)
            call_remote(:#{method_name}, args, &block)
          end
        EOM

      end
    end
    
    
    def authenticate(u,p)
      @creds = [u, p]
    end
    
    
    private
    def call_remote(method, args, &block)
      current_method = state[:remote_methods][method]
      call_url, params, request_method, wants_back, response_callback = current_method.calling(args, &block)
      
      method = request_method.to_s.capitalize
      
      url = URI.parse(call_url)
      req = Net::HTTP.const_get(method).new(url.path)
      
      
      # Set basic auth if provded
      auth = @creds || state[:auth]
      if(auth)
        req.basic_auth(auth[0], auth[1])
      end
      
      # set our form data
      req.set_form_data(self.class.flatten(params))

      # make the call
      begin
        res = Net::HTTP.new(url.host, url.port).start {|http| http.request(req) }
        case res
        when Net::HTTPSuccess #, Net::HTTPRedirection
          if response_callback
            if wants == :body
              return response_callback.call(res.body)
            elsif wants == :object
              return response_callback.call(res)
            end
          else
            return res.body
          end
        else
          raise "unhandled response type: #{res.inspect}"
        end
      rescue
        raise "unknown server error: #{$!.message}"
      end

      
      
    end
    
    
    def state
      @@state[self.class]
    end
    
    def self.flatten(params)
      params = params.dup
      params.stringify_keys!.each do |k,v| 
        if v.is_a? Hash
          params.delete(k)
          v.each {|subk,v| params["#{k}[#{subk}]"] = v }
        end
      end
    end
    
    
  end
  
  
  class RemoteMethod
    attr_accessor :method_name, :default_parameter_stack, 
      :override_parameter_stack, :service_url, 
      :request_method, :response_callback, :wants, :required_parameters
    
    def initialize(opts = {}, &response_callback)
      opts = {:wants => :body, :default_parameter_stack => [], 
        :override_parameter_stack => {}, :request_method => :get,
        :required_parameters => []}.merge(opts)
        
      opts.each do |k,v|
        self.send("#{k}=", v)
      end
      self.response_callback = response_callback
    end
    
    def calling(arguments = {}, &block)

      total_params = priority_merge(self.default_parameter_stack + [arguments] + self.override_parameter_stack)
      missing_params = self.required_parameters - total_params.keys

      
      
      raise ArgumentError, "missing required parameters: #{missing_params.join(", ")}" unless missing_params.empty?
      
      processed_service_url = self.service_url.dup
      pre_call_params = total_params
      usable_call_params = pre_call_params.dup
      
      # We are removing params that are spliced into the URL
      pre_call_params.each do |k, v|
        processed_service_url.gsub!("{#{k}}") do
          usable_call_params.delete(k)
          # URI encode these, since they're going in the uri directly
          urlencode(v)
        end
      end
      [processed_service_url, usable_call_params, self.request_method, self.wants, block || self.response_callback]
      # call_url, params, request_method, response_callback
    end

    private
    
    def priority_merge(stack)
      ret = {}
      stack.each {|hash| ret.merge!(hash)}
      ret
    end
    
    def urlencode(str)
      str.gsub(/[^a-zA-Z0-9_\.\-]/n) {|s| sprintf('%%%02x', s[0]) }
    end
    
  end
  
  
end