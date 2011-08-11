#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2011, Centre National de la Recherche Scientifique (CNRS)        #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
    RUBY_LIB_LOCATION="/usr/lib/one/ruby"
    VMDIR="/var/lib/one"
else
    RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
    VMDIR=ONE_LOCATION+"/var"
end

$: << RUBY_LIB_LOCATION

require 'OpenNebula'
include OpenNebula

require 'rubygems'
require 'bunny'

if !(vm_id=ARGV[0])
  puts "Error: supply VM ID"
  exit -1
end

if !(vm_state=ARGV[1])
  puts "Error: supply VM state"
  exit -1
end

begin
  client = Client.new()
rescue Exception => e
  puts "Error: #{e}"
  exit(-1)
end

vm = VirtualMachine.new(VirtualMachine.build_xml(vm_id), client)

vm.info

vm.each('TEMPLATE/NOTIFICATION') do |msg_coords| 

  message = "VM_ID=#{vm_id}; STATE=#{vm_state}";

  puts "#{msg_coords}\n";

  host = msg_coords["HOST"]
  vhost = msg_coords["VHOST"]
  user = msg_coords["USER"]
  password = msg_coords["PASSWORD"]
  queue = msg_coords["QUEUE"]

  b = Bunny.new(:user => user,
                :pass => password,
                :host => host,
                :vhost => vhost)

  b.start

  q = b.queue(queue)

  q.publish(message);

  puts "sent message (#{message}) to queue #{queue}\n"

  b.stop

end
