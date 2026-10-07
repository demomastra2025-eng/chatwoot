require 'rails_helper'

# config/integration/apps.yml is edited through shells and scripts. A console with the wrong encoding turns every Russian
# letter into '?'; the file stays valid YAML and the integration forms then show "????? ??????" (it happened to the
# MedElement form labels). This guard fails on such values, whatever app they belong to.
# rubocop:disable RSpec/DescribeClass
describe 'Integration apps configuration encoding' do
  # rubocop:enable RSpec/DescribeClass
  # Same source and loader as config/initializers/00_init.rb (APPS_CONFIG).
  let(:config) { YAML.load_file(Rails.root.join('config/integration/apps.yml')) }

  def damaged_paths(node, path = [])
    case node
    when Hash then node.flat_map { |key, value| damaged_paths(value, path + [key]) }
    when Array then node.each_with_index.flat_map { |value, index| damaged_paths(value, path + [index]) }
    when String then damaged_string?(node) ? [path.join('.')] : []
    else []
    end
  end

  def damaged_string?(value)
    value.match?(/\?{3,}/) || value.include?(replacement_character)
  end

  # U+FFFD, built from its code point so that this file does not carry the character itself.
  def replacement_character
    [0xFFFD].pack('U')
  end

  it 'finds damaged values in nested hashes and arrays and leaves healthy ones alone' do
    sample = {
      'app' => {
        'settings_form_schema' => [{ 'label' => '?????? ???', 'help' => 'API key?' }, { 'label' => "Key#{replacement_character}" }],
        'url' => 'https://example.com/path?a=1&b=2'
      }
    }

    expect(damaged_paths(sample)).to eq(%w[app.settings_form_schema.0.label app.settings_form_schema.1.label])
  end

  it 'has no value that lost its letters to a lossy encoding (three or more "?" in a row, or U+FFFD)' do
    paths = damaged_paths(config)

    expect(paths).to be_empty, "config/integration/apps.yml has damaged text values (re-save the file as UTF-8): #{paths.join(', ')}"
  end
end
