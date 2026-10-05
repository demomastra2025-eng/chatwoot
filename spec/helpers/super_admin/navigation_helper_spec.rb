require 'rails_helper'

RSpec.describe SuperAdmin::NavigationHelper do
  describe '#super_admin_environment_label' do
    it 'returns nothing in production' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect(helper.super_admin_environment_label).to be_nil
    end

    it 'returns the upcased environment name outside production' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('staging'))

      expect(helper.super_admin_environment_label).to eq('STAGING')
    end
  end
end
