Puppet::Type.newtype(:likewise_open_setting) do
  @doc = 'Manages Likewise Open settings'

  newparam(:name) do
    desc 'The setting name.'
  end

  newproperty(:value) do
    desc 'The setting value.'

    isrequired

    munge do |value|
      # make sure the value is a String
      value.to_s
    end

    def retrieve
      @resource.provider.get()
    end

    def sync
      @resource.provider.set()
    end
  end
end
