#!/usr/bin/env ruby

# ----------------------------------------------------------------------
# @authors      Clément Gauthey <clement.gauthey@ibcp.fr>
# @description  One hook script to manage port address translation on
#               StratusLab frontend
# ----------------------------------------------------------------------


# --- Modules ----------------------------------------------------------

ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
    RUBY_LIB_LOCATION="/usr/lib/one/ruby"
else
    RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
end

$: << RUBY_LIB_LOCATION

require 'optparse'
require 'OpenNebula'
require 'patcore'

include OpenNebula
include PATCore

# --- Variables --------------------------------------------------------

$verbose = false

# --- Functions --------------------------------------------------------

def log(message)
    puts ":: #{message}" if $verbose
end

# --- Classes ----------------------------------------------------------

# A class to manage port address translation.
class PATHook
    DEFAULT_MAX_ASSIGN = 5
    DEFAULT_LOCAL_IF = 'eth0'
    DEFAULT_REMOTE_PORTS = [22]
    DEFAULT_NETWORKS = ['local']
    DEFAULT_CHAIN_PREFIX = 'PAT'

    # Initialize a new PAT hook.
    #
    # @param [Hash] params parameters to initialize PAT hook
    def initialize(id, params)
        @ports = Ports.new(params[:file], params[:minport], params[:maxport])
        @firewall = Firewall.new({:chain_prefix => params[:chain_prefix] || DEFAULT_CHAIN_PREFIX})

        @rports = params[:rports] || DEFAULT_REMOTE_PORTS
        @max_assign = params[:max_assign] || DEFAULT_MAX_ASSIGN
        @networks = params[:networks] || DEFAULT_NETWORKS

        self.set_local_info(params[:local_ip], params[:local_if])
        self.set_remote_info(id)

        raise PATError, "Undefined remote IP." if not @remote_ip
        raise PATError, "Undefined local IP." if not @local_ip
        raise NotEligibleError, "Remote not eligible to PAT." if not self.eligible?
    end

    # Set local information.
    #
    # @param [String] interface the interface to use
    # @param [String] ip the IP address to use
    def set_local_info(ip, interface)
        @local_ip = ip || get_ip_address()
        @local_if = interface || DEFAULT_LOCAL_IF
    end

    # Set remote information.
    #
    # @param [Integer] vmid the identifier of the remote machine
    def set_remote_info(vmid)
        client = Client.new()
        vm = VirtualMachine.new(VirtualMachine.build_xml(vmid), client)
        rc = vm.info
        if OpenNebula.is_error?(rc):
            raise PATError, rc.to_str
        end
        @remote_id = vm.id
        @remote_ip = vm['TEMPLATE/NIC/IP']
        @remote_network = vm['TEMPLATE/NIC/NETWORK']
    end

    # Tell if the remote machine is eligible for port translation.
    #
    # @return [Boolean] true if it can, false else
    def eligible?()
        @networks.include? @remote_network
    end

    # Tell if the remote machine can accept new port translations.
    #
    # @return [Boolean] true if it can, false else
    def assignable?()
        current = @ports.get_ports_translations(@remote_id).size
        @max_assign == 0 or @max_assign > current
    end

    # Add a port translation for each remote ports.
    def add_port_translations()
        @rports.each do |rport|
            log "try to add port #{rport}"

            if not self.assignable?
                log "reached the maximum number of ports allowed by machine (#{@max_assign})"
                break
            end
            if not @ports.get_local_port(@remote_id, rport).nil?
                log "translation for remote port #{rport} already exists (skip)"
                next
            end

            begin
                lport = @ports.assign_local_port(@remote_id, rport)
                @firewall.insert(:pat, {:local_if => @local_if, :local_ip => @local_ip,
                                 :local_port => lport, :remote_ip => @remote_ip,
                                 :remote_port => rport})
                log "added port translation #{lport} => #{rport}"
            rescue FirewallError
                @ports.delete_port_translations(@remote_id, rport, lport)
                log "couldn't add translation for remote port #{rport}"
            end
        end
    end

    # Delete the port translation for each remote ports.
    def delete_port_translations()
        @rports.each do |rport|
            log "try to delete port #{rport}"

            lport = @ports.get_local_port(@remote_id, rport)
            if not lport
                log "translation for remote port #{rport} doesn't exist (skip)"
                next
            end

            begin
                @firewall.delete(:pat, {:local_if => @local_if, :local_ip => @local_ip,
                                 :local_port => lport, :remote_ip => @remote_ip,
                                 :remote_port => rport})
                @ports.delete_port_translations(@remote_id, rport)
                log "port translation #{lport} => #{rport} was removed"
            rescue FirewallError
                log "couln't delete translation for remote port #{rport}"
            end
        end
    end
end

# A class to handle command line for port address translation hook.
class PATHookCommand < PATHook
    VERSION = "0.2.0"

    # Initialize a new PATHookCommand object.
    #
    # @param [Array] args arguments from command line
    def initialize(args)
        options = {}
        opts = OptionParser.new do |opts|
            opts.banner = "Usage: pathook.rb <options> <add|del> <remote-id>"
            opts.define_head """
The script is intended to configure port address translation on a StratusLab
frontend. It can also be used as a One hook script to automatically open/close
firewall ports at VM startup/shutdown.

A task and a VM identifier are required in order to work. The task can be
either adding port translation (add) or removing port translation (del).
"""

            opts.separator ""
            opts.separator "Port translation options"
            opts.on("-p", "--ports X,Y,Z", Array, "Remote ports to translate (default: #{DEFAULT_REMOTE_PORTS.join(',')})") do |list|
                options[:rports] = list.map {|x| Integer(x)}
            end
            opts.on("-l", "--local-ip IP", "Local IP address (default: #{get_ip_address})") do |ip|
                options[:local_ip] = ip
            end
            opts.on("-i", "--local-if IF", "Local interface name (default: #{DEFAULT_LOCAL_IF})") do |ifname|
                options[:local_if] = ifname
            end
            opts.on("-r", "--local-range X:Y", "Local ports range used to translate remote ports (default: #{Ports::LIMIT_MIN_PORT}:#{Ports::LIMIT_MAX_PORT})") do |range|
                options[:minport], options[:maxport] = range.split(':', 2).map {|x| Integer(x) if not x.empty?}
            end
            opts.on("-c", "--chain-prefix PREFIX",
                    "Prefix to add to firewall default chains, e.g. FORWARD will become PREFIX-FORWARD (default: #{DEFAULT_CHAIN_PREFIX})",
                    "WARNING: resulting chains MUST exist in the firewall") do |opt|
                options[:chain_prefix] = opt
            end
            opts.on("-m", "--max-assign MAX", Integer,
                    "Maximum number of translations authorized per remote machine (default: #{DEFAULT_MAX_ASSIGN})",
                    "Set value to 0 to unlimited assignments") do |max|
                options[:max_assign] = max
            end
            opts.on("-n", "--networks X,Y,Z", "Virtual networks used to translate ports (default: #{DEFAULT_NETWORKS.join(',')})") do |networks|
                options[:networks] = networks
            end
            opts.on("-f", "--file FILE", "Ports translations file (default: #{Ports::DEFAULT_FILE})") do |file|
                options[:file] = file
            end

            opts.separator ""
            opts.separator "Common options"
            opts.on_tail("-v", "--[no-]verbose", "Verbose mode (default: #{$verbose})") do |b|
                $verbose = b
            end
            opts.on_tail("-h", "--help", "Summary help") do
                puts opts
                exit
            end
            opts.on_tail("--version", "Show version") do
                puts "PATHook version #{VERSION}"
                exit
            end
        end

        opts.parse!(args)

        # Manage mandatory arguments
        raise OptionParser::MissingArgument, "Undefined task and/or remote identifier." if args.size != 2
        @task = args[0]
        id = Integer(args[1])

        super(id, options)
    end

    # Run core processes.
    def run()
        case @task
        when /add/
            self.add_port_translations
        when /del/
            self.delete_port_translations
        end
    end
end

# --- Main -------------------------------------------------------------

if __FILE__ == $0
    begin
        p = PATHookCommand.new(ARGV)
        p.run
    rescue NotEligibleError => error
        log error
    rescue StandardError => error
        puts "An error occured during PAT operations."
        puts error
        exit(1)
    end
end

