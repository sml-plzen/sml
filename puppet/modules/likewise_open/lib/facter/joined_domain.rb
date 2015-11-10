# Fact: joined_domain
#
# Purpose: Returns the name of the AD domain the node is member of.
#
# Caveats:
#
require 'puppet'
require 'puppet/util'

Facter.add(:joined_domain) do
  setcode do
    joined_domain = nil
    if command = Puppet::Util::which('domainjoin-cli')
      Puppet::Util::execute([command, 'query']).each_line do |line|
        if line =~ /^Domain\s*=\s*(.*)$/
          joined_domain = $1
          break
        end
      end
    end
    joined_domain
  end
end
