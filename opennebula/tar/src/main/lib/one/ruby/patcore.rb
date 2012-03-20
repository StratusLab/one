#!/usr/bin/env ruby

# ----------------------------------------------------------------------
# @authors      Clément Gauthey <clement.gauthey@ibcp.fr>
# @description  Core file for port address translation on a StratusLab
#               cloud
# ----------------------------------------------------------------------


require 'sqlite3'
require 'socket'

module PATCore

    # A class to handle port translation data.
    class Ports
        LIMIT_MAX_PORT = 65535
        LIMIT_MIN_PORT = 1024

        DEFAULT_TIMEOUT = 15    # timeout (sec) before aborting current operation
        DEFAULT_FILE = '/var/lib/one/ports.db'

        SQL_CREATE_TABLE = """
    CREATE TABLE ports (
        id VARCHAR(32) NOT NULL,
        local INTEGER NOT NULL UNIQUE,
        remote INTEGER NOT NULL,
        CONSTRAINT ports_pk PRIMARY KEY (id, local, remote)
    )
        """

        # Initialize a new Ports object.
        #
        # @param [String] file the filepath for storing data
        # @param [Integer] minport minimal usable port
        # @param [Integer] maxport maximal usable port
        def initialize(file=nil, minport=nil, maxport=nil)
            @file = file || DEFAULT_FILE
            @minport = minport || LIMIT_MIN_PORT
            @maxport = maxport || LIMIT_MAX_PORT

            raise ArgumentError, "InvalidPortsRange" if @minport >= @maxport || @maxport > LIMIT_MAX_PORT || @minport < LIMIT_MIN_PORT

            # Create or/and open database
            if not File.exists? @file
                @db = SQLite3::Database.new(@file)
                @db.execute(SQL_CREATE_TABLE)
            else
                @db = SQLite3::Database.new(@file)
            end
            @db.type_translation = true
            @db.busy_timeout(1000);
        end

        # Get all local ports.
        #
        # @return [Array] a list of all local ports
        def get_all_local_ports()
            @db.execute("SELECT DISTINCT(local) FROM ports").flatten
        end

        # Get all remote ports.
        #
        # @return [Array] a list of all remote ports
        def get_all_remote_ports()
            @db.execute("SELECT DISTINCT(remote) FROM ports").flatten
        end

        # Get all ports translations.
        #
        # @return [Hash] all ports translations {machine => {remote => local, ...}, ...}
        def get_all_ports_translations()
            res = @db.execute("SELECT id, local, remote FROM ports")
            ports = {}
            res.each do |id,local,remote|
                ports[id] = {} if not ports[id]
                ports[id][remote] = local
            end
            ports
        end

        # Get local ports of a specified machine.
        #
        # @param [String] machine machine to get local ports
        # @return [Array] local ports of the specified machine
        def get_local_ports(machine)
            @db.execute("SELECT local FROM ports WHERE id = ?", machine).flatten
        end

        # Get remote ports of a specified machine.
        #
        # @param [String] machine machine to get remote ports
        # @return [Array] remote ports of the specified machine
        def get_remote_ports(machine)
            @db.execute("SELECT remote FROM ports WHERE id = ?", machine).flatten
        end

        # Get ports translations for a specified machine.
        #
        # @param [String] machine machine to get port translations
        # @return [Hash] port translations (local => remote) of the specified machine
        def get_ports_translations(machine)
            Hash[*@db.execute("SELECT local, remote FROM ports WHERE id = ?", machine).flatten]
        end

        # Get the local port associated to a remote port for a specified machine.
        #
        # @param [String] machine machine to get local port
        # @param [Integer] rport remote port to search translation
        # @return [Integer] local port or nil if no translation
        def get_local_port(machine, rport)
            @db.get_first_value("SELECT local FROM ports WHERE id = ? AND remote = ?", machine, rport)
        end

        # Get the remote port associated to a local port for a specified machine.
        #
        # @param [String] machine machine to get remote port
        # @param [Integer] lport local port to search translation
        # @return [Integer] remote port or nil if no translation
        def get_remote_port(machine, lport)
            @db.get_first_value("SELECT remote FROM ports WHERE id = ? AND local = ?", machine, lport)
        end

        # Add a port translation to ports data.
        #
        # @param [String] machine machine identifier
        # @param [Integer] rport remote port to add
        # @param [Integer] lport local port to add
        def add_port_translation(machine, rport, lport)
            @db.execute("INSERT INTO ports (id, local, remote) VALUES(?, ?, ?)", machine, lport, rport)
        end

        # Delete port translations from ports data.
        #
        # @param [String] machine machine identifier
        # @param [Integer] rport remote port to delete
        # @param [Integer] lport local port to delete
        def delete_port_translations(machine, rport=nil, lport=nil)
            req = "DELETE FROM ports WHERE id = :id"
            bind = {:id => machine}
            if rport
                req += " AND remote = :remote"
                bind[:remote] = rport
            end
            if lport
                req += " AND local = :local"
                bind[:local] = lport
            end

            @db.execute(req, bind)
        end

        # Assign a local port to a remote port.
        #
        # @param [String] machine machine identifier
        # @param [Integer] rport remote port
        # @return [Integer] the assigned local port
        def assign_local_port(machine, rport)
            timeout = Time.now + DEFAULT_TIMEOUT
            begin
                lport = next_free_local_port
                raise PATError, "Couldn't found a local port." unless lport
                add_port_translation machine, rport, lport
            rescue SQLite3::SQLException        # manage concurrency
                retry if timeout > Time.now
                raise PATError, "Couldn't found a local port."
            end
            lport
        end

        # Return the next free local port.
        #
        # @param [Boolean] lowest select the lowest port
        # @return [Integer] the next free local port
        def next_free_local_port(lowest=false)
            free_ports = get_all_free_local_ports
            lowest ? free_ports.min : free_ports.first
        end

        # Return a number of (sequential) free local ports.
        #
        # @param [Integer] count number of free ports to return
        # @param [Boolean] seq select sequential ports
        # @return [Array] a list of free local ports, or nil if none
        def get_free_local_ports(count, seq=false)
            free_ports = get_all_free_local_ports
            return nil if free_ports.size < count

            count -= 1      # include begin port
            start = nil
            if seq
                free_ports.sort!
                free_ports.each_index do |idx|
                    break if idx + count >= free_ports.size
                    if free_ports[idx] + count == free_ports[idx + count]
                        start = idx
                        break
                    end
                end
            else
                start = 0
            end

            return nil if not start
            free_ports[start..count]
        end

        # Get all free local ports.
        #
        # @return [Array] the list of free local ports
        def get_all_free_local_ports()
            (@minport..@maxport).to_a - get_all_local_ports
        end
    end

    # A class to manage iptables firewall.
    #
    # Most of the methods work with defined firewall rulesets. A ruleset is defined
    # by a set of rules and a callback to build the final rules. The builder
    # callback can be a function (call) or a method of the class (__send__) which
    # takes two parameters: the rules and the parameters to fill them.
    #
    class Firewall
        DEFAULT_COMMAND = '/sbin/iptables'
        DEFAULT_TASKS = {:insert => '-I', :append => '-A', :delete => '-D'}
        DEFAULT_SUDO = true
        DEFAULT_CHAIN_PREFIX = nil
        DEFAULT_RULESETS = {
            :pat => {
                :builder => :build_pat_rules,
                :require => [:task, :local_ip, :local_if, :local_port,
                             :remote_ip, :remote_port],
                :rules => [# task prefix local_if local_ip local_port remote_ip remote_port
                           "-t nat %s %sPREROUTING -i %s -d %s -p tcp --dport %s -j DNAT --to %s:%s",
                           # task prefix local_if remote_ip remote_port
                           "-t filter %s %sFORWARD -i %s -d %s -p tcp --dport %s -j ACCEPT"]}
        }

        # Initialize a new firewall instance.
        #
        # @param [Hash] args various firewall optional parameters
        def initialize(args={})
            @command = args[:command] || DEFAULT_COMMAND
            @tasks = args[:tasks] || DEFAULT_TASKS
            @sudo = args[:sudo] || DEFAULT_SUDO
            @rulesets = args[:rulesets] || DEFAULT_RULESETS
            @chain_prefix = args[:chain_prefix] || DEFAULT_CHAIN_PREFIX

            raise ArgumentError, "Undefined firewall command." if @command.empty?
            raise ArgumentError, "Undefined firewall task." if @tasks.empty?
        end

        # Append a ruleset to firewall rules.
        #
        # @param [Symbol] ruleset the name of the ruleset to append
        # @param [Hash] params the parameters for the rules of the ruleset
        def append(ruleset, params)
            params[:task] = :append
            self.apply(ruleset, params)
        end

        # Insert a ruleset to firewall rules.
        #
        # @param [Symbol] ruleset the name of the ruleset to insert
        # @param [Hash] params the parameters for the rules of the ruleset
        def insert(ruleset, params)
            params[:task] = :insert
            self.apply(ruleset, params)
        end

        # Delete a ruleset to firewall rules.
        #
        # @param [Symbol] ruleset the name of the ruleset to delete
        # @param [Hash] params the parameters for the rules of the ruleset
        def delete(ruleset, params)
            params[:task] = :delete
            self.apply(ruleset, params)
        end

        # Apply a ruleset on the firewall.
        #
        # @param [Symbol] ruleset the name of the ruleset to apply
        # @param [Hash] params the parameters for the rules of the ruleset
        def apply(ruleset, params)
            if not @rulesets.member? ruleset
                raise RulesetError, "Undefined firewall ruleset '#{ruleset}'."
            end

            rules = self.build(ruleset, params)
            rules.each do |rule|
                self.execute(rule)
            end
        end

        # Execute a rule on the firewall.
        #
        # @param [String] rule the rule to execute
        def execute(rule)
            command = @command
            if @sudo
                command = "sudo #{command}"
            end

            if not system "#{command} #{rule}"
                raise FirewallError, "Couldn't configure firewall."
            end
        end

        # Build the rules of a ruleset with given parameters
        #
        # @param [Symbol] ruleset the name of the ruleset to build
        # @param [Hash] params the list of parameters to use
        # @return [Array] the fulfilled rules
        def build(ruleset, params)
            if not self.can_build?(ruleset, params)
                raise RulesetError, "Couldn't build firewall ruleset '#{ruleset}'."
            end
            if self.respond_to? @rulesets[ruleset][:builder]
                return self.__send__(@rulesets[ruleset][:builder],
                                     @rulesets[ruleset][:rules],
                                     params)
            else
                return @rulesets[ruleset][:builder].call(@rulesets[ruleset][:rules],
                                                         params)
            end
        end

        # Build the port translation rules from given parameters.
        #
        # @param [Array] raw_rules the raw rules to translate into complete rules
        # @param [Hash] params the parameters to fill the raw rules
        # @return [Array] the complete rules
        def build_pat_rules(raw_rules, params)
            rules = []
            rules << raw_rules[0] % [@tasks[params[:task]], @chain_prefix + '-',
                                     params[:local_if], params[:local_ip], params[:local_port],
                                     params[:remote_ip], params[:remote_port]]
            rules << raw_rules[1] % [@tasks[params[:task]], @chain_prefix + '-',
                                     params[:local_if], params[:remote_ip], params[:remote_port]]
            return rules
        end

        # Check if rules of a ruleset can be built.
        #
        # @param [Symbol] ruleset the ruleset to check
        # @param [Hash] params the parameters to build the rules of the ruleset
        # @return [Boolean] true if rules can be built, false else
        def can_build?(ruleset, params)
            @rulesets[ruleset][:require].each do |param|
                if not params.member? param
                    return false
                end
            end
            return true
        end
    end

    # A class to handle port translation exception.
    class PATError < StandardError; end
    class NotEligibleError < PATError; end
    class FirewallError < PATError; end
    class RulesetError < FirewallError; end

    # Utility functions.

    # Get the IP address of the machine.
    #
    # @return [String] an IP address
    def get_ip_address()
        ip = nil
        UDPSocket.open do |s|
            s.connect('1.2.3.4', 1)
            ip = s.addr.last
        end
        return ip
    end
end

