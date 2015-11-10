Puppet::Parser::Functions::newfunction(:defined_with_params, :type => :rvalue, :doc => "
  Takes a resource reference and an optional hash of attributes.

  Returns true if a resource with the specified attributes has already been added to the
  catalog, and false otherwise.

    user { 'dan':
      ensure => present,
    }

    if ! defined_with_params(User[dan], {'ensure' => 'present' }) {
      user { 'dan': ensure => present, }
    }
") do |arguments|
  raise(ArgumentError, "defined_with_params(): Wrong number of " +
    "arguments given (#{arguments.size} for 1 or 2)") if (arguments.size < 1 || arguments.size > 2)
  reference, params = arguments
  raise(ArgumentError, 'defined_with_params(): Requires a resource reference to work with') unless reference.is_a?(Puppet::Resource)
  params ||= {}
  ret = (resource = findresource(reference.to_s)) ? params.all? { |key, value| resource[key] == value } : false
  Puppet.debug("defined_with_params(): A resource matching #{reference}#{params.inspect} is#{ret ? " " : " NOT "}defined")
  ret
end
