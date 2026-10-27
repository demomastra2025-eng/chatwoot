require 'rails_helper'

RSpec.describe Scheduling::IinValidator do
  describe '.require_valid!' do
    it 'gives the digits of an IIN of 12 digits with the check digit, whatever the spaces and dashes' do
      expect(described_class.require_valid!('900101300027')).to eq('900101300027')
      expect(described_class.require_valid!(' 900101 300027 ')).to eq('900101300027')
      expect(described_class.require_valid!('900101-300027')).to eq('900101300027')
      expect(described_class.require_valid!('850505501230')).to eq('850505501230')
    end

    it 'has nothing to write for a missing or blank value' do
      expect(described_class.require_valid!(nil)).to be_nil
      expect(described_class.require_valid!('')).to be_nil
      expect(described_class.require_valid!("  \n")).to be_nil
    end

    # Suggestion eval 27.10 (c74-1245386): a payment phone number the patient sent was read as the ID number.
    it 'refuses a phone number, a number of the wrong length, a wrong check digit and text, and says why' do
      ['+7 701 123 45 67', '87011234567', '77011234567', '7011234567', '90010130002', '9001013000271', '900101300028', 'abc',
       'Kaspi 7011234567'].each do |value|
        expect { described_class.require_valid!(value) }
          .to raise_error(Scheduling::Error, /Invalid IIN: an IIN is 12 digits with a check digit, a phone number is not an IIN/), value
      end
    end

    it 'raises the error code of the other IIN checks' do
      expect { described_class.require_valid!('87011234567') }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('INVALID_IIN') }
    end
  end
end
