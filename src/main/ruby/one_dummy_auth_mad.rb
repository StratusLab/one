#!/usr/bin/env ruby


ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
    RUBY_LIB_LOCATION="/usr/lib/one/ruby"
    ETC_LOCATION="/etc/one/"
else
    RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
    ETC_LOCATION=ONE_LOCATION+"/etc/"
end

$: << RUBY_LIB_LOCATION

require 'rubygems'
require 'OpenNebulaDriver'
require 'simple_permissions'
require 'yaml'
require 'sequel'

class DummyAuthorizationManager < OpenNebulaDriver
    def initialize
        super(15, true)
        
        config_data=File.read(ETC_LOCATION+'/auth/auth.conf')
        STDERR.puts(config_data)
        @config=YAML::load(config_data)
        
        STDERR.puts @config.inspect
        
        database_url=@config[:database]
        @db=Sequel.connect(database_url)
        
        @permissions=SimplePermissions.new(@db, OpenNebula::Client.new,
            @config)

        register_action(:AUTHENTICATE, method('action_authenticate'))
        register_action(:AUTHORIZE, method('action_authorize'))
    end
    
    def action_authenticate(request_id, user_id, user, password, token)
        send_message('AUTHENTICATE', RESULT[:success],
            request_id, "#{user} #{token}")
    end
    
    def action_authorize(request_id, user_id, *tokens)
        auth=@permissions.auth(user_id, tokens.flatten)
        if auth==true
            send_message('AUTHORIZE', RESULT[:success],
                request_id, 'success')
        else
            send_message('AUTHORIZE', RESULT[:failure],
                request_id, auth)
        end
    end
end


am=DummyAuthorizationManager.new
am.start_driver

