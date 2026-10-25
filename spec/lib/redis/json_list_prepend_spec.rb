require 'rails_helper'

RSpec.describe Redis::JsonListPrepend do
  let(:key) { "spec:json_list:#{SecureRandom.hex(4)}" }

  def list
    JSON.parse(Redis::Alfred.get(key))
  end

  after { Redis::Alfred.delete(key) }

  it 'puts the value at the front once, keeps the first values up to the limit and sets the expiry' do
    %w[a b c].each { |value| Redis::Alfred.prepend_to_json_list(key, value, limit: 3, ex: 60) }
    Redis::Alfred.prepend_to_json_list(key, 'b', limit: 3, ex: 60)
    Redis::Alfred.prepend_to_json_list(key, 'd', limit: 3, ex: 60)

    expect(list).to eq(%w[d b c])
    expect($alfred.with { |connection| connection.ttl(key) }).to be_within(2).of(60) # rubocop:disable Style/GlobalVars
  end

  it 'starts over from a value that is not a JSON list' do
    Redis::Alfred.set(key, 'not json')

    Redis::Alfred.prepend_to_json_list(key, 'a', limit: 3, ex: 60)

    expect(list).to eq(['a'])
  end
end
