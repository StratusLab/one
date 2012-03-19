#!/usr/bin/env ruby

# ----------------------------------------------------------------------
# @authors      Clément Gauthey <clement.gauthey@ibcp.fr>
# @description  Script to restore port address translation on StratusLab
#               cloud
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

# A class to handle the restoration of port address translation.
class PATRestorer
    DEFAULT_NETWORKS = ['local']
    DEFAULT_STATES = ['ACTIVE']
    DEFAULT_SANITIZE = false
    DEFAULT_LOCAL_IF = 'eth0'
    DEFAULT_CHAIN_PREFIX = 'PAT'

    def initialize(args)
        @ports = Ports.new(args[:file], args[:minport], args[:maxport])
        @firewall = Firewall.new({:chain_prefix => args[:chain_prefix] || DEFAULT_CHAIN_PREFIX})

        @local_ip = args[:local_ip] || get_ip_address
        @local_if = args[:local_if] || DEFAULT_LOCAL_IF

        @networks = args[:networks] || DEFAULT_NETWORKS
        @states = args[:states] || DEFAULT_STATES
        @sanitize = args[:sanitize] || DEFAULT_SANITIZE

        @vm_pool = self.get_all_vms()

        raise ArgumentError, "Undefined local IP." if @local_ip.empty?
    end

    # Get all the virtual machines of the cloud.
    #
    # @return [Object] a virtual machines pool
    def get_all_vms()
        client = Client.new()
        pool = VirtualMachinePool.new(client, -2)
        rc = pool.info
        if OpenNebula.is_error?(rc):
            raise PATError, rc.to_str
        end
        return pool
    end

    # Get information about a single virtual machine.
    #
    # @param [Integer] vmid the identifier of the VM to find
    # @return [Object] VirtualMachine the found virtual machine
    def get_single_vm(vmid)
       @vm_pool.each do |vm|
          return vm if vm.id == vmid
       end
       return nil
    end

    # Restore firewall rules from port translation database.
    def restore_port_translation()
        log "scan port translation database"
        @ports.get_all_ports_translations.each do |vmid, ports|
            log "found VM #{vmid}"
            vm = self.get_single_vm(vmid.to_i)

            if self.use_port_translation?(vm)
                ports.each do |remote, local|
                    @firewall.insert(:pat, {:local_ip => @local_ip, :local_if => @local_if,
                                     :local_port => local, :remote_ip => vm['TEMPLATE/NIC/IP'],
                                     :remote_port => remote})
                    log "restore port translation #{local} => #{remote} for VM #{vmid}"
                end
            else
                if @sanitize
                    # Sanitize the database by removing useless port translation
                    @ports.delete_port_translations(vmid)
                    log "remove useless port translation for VM #{vmid}"
                end
            end
        end
    end

    # Tell if a virtual machine can use port translation.
    #
    # @param [Object] vm the virtual machine to check
    # @return [Boolean] true if the virtual machine can, false else
    def use_port_translation?(vm)
        not vm.nil? and @networks.include?(vm['TEMPLATE/NIC/NETWORK']) and @states.include?(vm.state_str)
    end
end

# A class to handle command-line for port address translation restorer.
class PATRestorerCommand < PATRestorer
    VERSION = "0.1.0"

    def initialize(args)
        options = {}
        opts = OptionParser.new do |opts|
            opts.banner = "Usage: patrestorer.rb <options>"
            opts.define_head """
The script is intended to restore port address translation in a StratusLab
cloud. It is very usefull after restarting the gateway host since the port
translation rules can be lost on the firewall.

In additional, it tries to be consistent with the current cloud state. That's
why it can sanitize the port translation file.

WARNING: no PAT iptables rules must be set before running this script."""

            opts.separator ""
            opts.separator "Restoration options"
            opts.on("-l", "--local-ip IP", "Local IP address (default: #{get_ip_address})") do |ip|
                options[:local_ip] = ip
            end
            opts.on("-i", "--local-if IF", "Local interface name (default: #{DEFAULT_LOCAL_IF})") do |ifname|
                options[:local_if] = ifname
            end
            opts.on("-n", "--networks X,Y,Z", Array, "Networks used to translate ports (default: #{DEFAULT_NETWORKS.join(',')})") do |networks|
                options[:networks] = networks
            end
            opts.on("-s", "--states X,Y,Z", Array, "VM states in which PAT is enable (default: #{DEFAULT_STATES.join(',')})") do |states|
                options[:states] = states
            end
            opts.on("-c", "--chain-prefix PREFIX",
                    "Prefix to add to firewall default chains, e.g. FORWARD will become PREFIX-FORWARD (default: #{DEFAULT_CHAIN_PREFIX})",
                    "WARNING: resulting chains MUST exist in the firewall") do |opt|
                options[:chain_prefix] = opt
            end
            opts.on("-f", "--file FILE", "Port translation file (default: #{Ports::DEFAULT_FILE})") do |file|
                options[:file] = file
            end
            opts.on("-z", "--[no-]sanitize",
                    "Remove inconsistency in port translation file (default: #{DEFAULT_SANITIZE})",
                    "WARNING: destructive option, so use carefully") do |sanitize|
                options[:sanitize] = sanitize
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
                puts "PATRestorer version #{VERSION}"
                exit
            end
        end

        opts.parse!(args)
        super(options)
    end

    def run()
        self.restore_port_translation
    end
end

# --- Main -------------------------------------------------------------

if __FILE__ == $0
    begin
        p = PATRestorerCommand.new(ARGV)
        p.run
    rescue StandardError => error
        puts "An error occured during PAT restoration."
        puts error
        exit(1)
    end
end

