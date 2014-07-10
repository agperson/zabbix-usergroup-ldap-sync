#!/usr/bin/env ruby

require 'rubygems'
require 'zabbixapi'
require 'ldap'
require 'yaml'

# Cheap way of referencing a config as an object
class ::Hash
  def method_missing(name)
    return self[name] if key? name
    self.each { |k,v| return v if k.to_s.to_sym == name }
    super.method_missing name
  end
end

# Load configuration file
config = YAML.load_file(File.join(File.dirname(__FILE__), 'config.yaml'))

# Connect to Zabbix API endpoint
zabbix = ZabbixApi.connect(
  :url      => config.zabbix.host,
  :user     => config.zabbix.user,
  :password => config.zabbix.pass
)

# Connect to LDAP server
ldap = LDAP::Conn.new(config.ldap.host, config.ldap.port)

# Iterate through each group
config.groups.each do |group|
  puts "Beginning update of group #{group}"
  # Find the group in Zabbix.  If it does not exist, create it.
  grpid = zabbix.usergroups.get_or_create(:name => group)
  puts "- Zabbix group ID is #{grpid}"

  # Determine LDAP group membership
  filter = "(&(objectclass=posixGroup)(cn=#{group}))"
  attrs  = "memberUid"
  ldap_membership = []

  begin
    ldap.search(config.ldap.base, LDAP::LDAP_SCOPE_SUBTREE, filter, attrs) do |entry|
      ldap_members = entry.vals('memberUid')

      # Remove DN results and keep just short username results
      ldap_members.delete_if { |u| u =~ /^uid=/ }

      ldap_members.each do |user|
        filter = "(&(objectclass=posixAccount)(uid=#{user}))"
        attrs  = [ "uid", "givenName", "sn", "mail" ] 
        begin
          ldap.search(config.ldap.base, LDAP::LDAP_SCOPE_SUBTREE, filter, attrs) do |entry|
            ldap_membership << entry.to_hash
          end
        rescue LDAP::ResultError
          ldap.perror("search")
          next
        end
      end
    end
  rescue LDAP::ResultError
    ldap.perror("search")
    next
  end

  # Find each user in Zabbix. If they do not exist, create them.
  userids = []
  ldap_membership.each do |user|
    uid = user["uid"].to_s
    response = zabbix.users.get_id(:alias => uid)
    if response.nil?
      response = zabbix.users.create(
        :alias          => uid,
        :name           => user["givenName"].to_s,
        :surname        => user["sn"].to_s,
        :passwd         => rand(36**12).to_s(36),
        :url            => "/zabbix/dashboard.php",
        :lang           => "en_GB",
        :autologin      => 0,
        :autologout     => 900,
        :refresh        => 300,
        :rows_per_page  => 50,
        :theme          => "originalblue",
        :type           => 1,
        :usrgrps        => [ 20 ] # Generic "Users" group
      )
      userids << response
      puts "- Created user #{uid} with ID #{response}."
    else
      puts "- Found existing user #{uid} with ID #{response}."
      userids << response
    end
  end

  # Update Zabbix group membership (Zabbix will automatically add/remove
  # users to achieve this result).
  puts "- Updating group #{group} (#{grpid}) to match LDAP"
  zabbix.usergroups.update_user(
    :usrgrpids  => grpid,
    :userids    => userids
  )
end

ldap.unbind
exit
