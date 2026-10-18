# frozen_string_literal: true

require 'rails_helper'
require 'erb'
require 'yaml'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Consolidated Sidekiq 7 capsules configuration' do
  def load_yaml(relative_path)
    rendered = ERB.new(Rails.root.join(relative_path).read).result
    YAML.safe_load(rendered, permitted_classes: [Symbol], aliases: true)
  end

  def extract_queue_names(queues_entry)
    Array(queues_entry).map { |item| item.is_a?(Array) ? item.first.to_s : item.to_s }
  end

  let(:legacy_configs) do
    Dir[Rails.root.join('config/sidekiq*.yml')]
      .map { |p| File.basename(p) }
      .reject { |name| name.start_with?('sidekiq_capsule') }
  end

  let(:all_legacy_queues) do
    legacy_configs.flat_map do |filename|
      config = load_yaml("config/#{filename}")
      extract_queue_names(config[:queues] || config['queues'])
    end.uniq.sort
  end

  let(:capsule_files) do
    %w[
      config/sidekiq_capsule_realtime.yml
      config/sidekiq_capsule_inbound_channels.yml
      config/sidekiq_capsule_ai_captain.yml
      config/sidekiq_capsule_voice_telephony.yml
      config/sidekiq_capsule_medelement.yml
      config/sidekiq_capsule_core_scheduled.yml
      config/sidekiq_capsule_history_maintenance.yml
    ]
  end

  it 'covers 100% of legacy Sidekiq queues plus voice_recording_transcription in config/sidekiq_capsules.yml' do
    capsules_config = load_yaml('config/sidekiq_capsules.yml')
    capsules = capsules_config[:capsules] || capsules_config['capsules']
    covered_queues = capsules.values.flat_map { |c| extract_queue_names(c[:queues] || c['queues']) }.uniq.sort

    expected = (all_legacy_queues + ['voice_recording_transcription']).uniq.sort
    expect(covered_queues).to match_array(expected)
  end

  it 'covers 100% of queues across the 7 consolidated container configs without overlap' do
    per_file_queues = capsule_files.flat_map do |path|
      config = load_yaml(path)
      extract_queue_names(config[:queues] || config['queues'])
    end

    expected = (all_legacy_queues + ['voice_recording_transcription']).uniq.sort
    expect(per_file_queues.uniq.sort).to match_array(expected)
    expect(per_file_queues.size).to eq(per_file_queues.uniq.size)
  end
end
# rubocop:enable RSpec/DescribeClass
