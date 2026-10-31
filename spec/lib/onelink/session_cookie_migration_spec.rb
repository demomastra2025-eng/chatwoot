require 'rails_helper'

RSpec.describe Onelink::SessionCookieMigration do
  let(:legacy_key) { '_chatwoot_session' }
  let(:current_key) { '_onelink_session' }
  let(:options) { { path: '/', httponly: true, same_site: :lax, secure: true } }

  def stack(key:, bridge: nil)
    endpoint = lambda do |env|
      request = ActionDispatch::Request.new(env)
      request.reset_session if request.path == '/logout'
      request.session.options[:drop] = true if request.path == '/drop'
      request.session[:identity] = request.get_header('HTTP_X_TEST_IDENTITY') if request.get_header('HTTP_X_TEST_IDENTITY')
      [200, { 'Content-Type' => 'application/json' }, [JSON.generate(identity: request.session[:identity])]]
    end
    app = ActionDispatch::Session::CookieStore.new(endpoint, **options, key: key)
    app = described_class.new(app, cookie_options: options, bridge: bridge, primary_key: key) unless bridge.nil?
    ActionDispatch::Cookies.new(app)
  end

  def visit(app, jar, path: '/', identity: nil)
    env = Rails.application.env_config.merge(Rack::MockRequest.env_for("https://example.test#{path}"))
    env['HTTP_COOKIE'] = jar.map { |key, value| "#{key}=#{value}" }.join('; ')
    env['HTTP_X_TEST_IDENTITY'] = identity if identity
    _status, headers, body = app.call(env)
    update_cookie_jar(jar, headers)
    [JSON.parse(body.each.to_a.join), headers]
  end

  def update_cookie_jar(jar, headers)
    Array(headers['Set-Cookie'] || headers['set-cookie']).flat_map { |line| line.split("\n") }.each do |line|
      name, value = line.split(';', 2).first.split('=', 2)
      value.blank? ? jar.delete(name) : jar[name] = value
    end
  end

  it 're-encrypts legacy sessions and preserves updates across old/new web replicas' do
    old = stack(key: legacy_key, bridge: true)
    current = stack(key: current_key, bridge: true)
    jar = {}
    visit(old, jar, identity: 'existing-session')
    expect(visit(current, jar).first['identity']).to eq('existing-session')
    expect(jar.keys).to contain_exactly(legacy_key, current_key)
    visit(old, jar, identity: 'updated-on-old-replica')
    expect(visit(current, jar).first['identity']).to eq('updated-on-old-replica')
    expect(visit(old, jar).first['identity']).to eq('updated-on-old-replica')
  end

  it 'does not issue canonical cookies until cookie-aware code is deployed to every replica' do
    jar = {}
    old = stack(key: legacy_key)
    aware_old = stack(key: legacy_key, bridge: true)
    visit(old, jar, identity: 'existing-session')
    visit(aware_old, jar)
    expect(jar.keys).to eq([legacy_key])
  end

  it 'rejects retirement while a replica still writes the legacy primary' do
    expect { stack(key: legacy_key, bridge: false) }.to raise_error(ArgumentError)
  end

  it 'propagates an old-primary replica logout/drop to the canonical alias' do
    aware_old = stack(key: legacy_key, bridge: true)
    current = stack(key: current_key, bridge: true)
    jar = {}
    visit(aware_old, jar, identity: 'existing-session')
    visit(current, jar)
    visit(aware_old, jar, path: '/drop')
    expect(visit(current, jar).first['identity']).to be_nil
  end

  it 'retains sessions across mixed bridge and retirement replicas' do
    jar = {}
    bridge_app = stack(key: current_key, bridge: true)
    retire_app = stack(key: current_key, bridge: false)
    visit(bridge_app, jar, identity: 'existing-session')
    [retire_app, bridge_app, retire_app].each do |app|
      expect(visit(app, jar).first['identity']).to eq('existing-session')
    end
    expect(jar.keys).to eq([current_key])
  end

  it 'imports old-only sessions and retires the alias after every replica supports the new name' do
    jar = {}
    visit(stack(key: legacy_key), jar, identity: 'existing-session')
    expect(visit(stack(key: current_key, bridge: false), jar).first['identity']).to eq('existing-session')
    expect(jar.keys).to eq([current_key])
    expect(visit(stack(key: current_key, bridge: false), jar).first['identity']).to eq('existing-session')
  end

  it 'does not resurrect a reset session from the legacy alias' do
    current = stack(key: current_key, bridge: true)
    jar = {}
    visit(stack(key: legacy_key), jar, identity: 'existing-session')
    visit(current, jar)
    expect(visit(current, jar, path: '/logout').first['identity']).to be_nil
    expect(visit(current, jar).first['identity']).to be_nil
    expect(visit(stack(key: legacy_key), jar).first['identity']).to be_nil
  end

  it 'rejects tampered old cookies and retains secure cookie attributes' do
    jar = { legacy_key => 'tampered' }
    body, headers = visit(stack(key: current_key, bridge: true), jar, identity: 'new-session')
    expect(body['identity']).to eq('new-session')
    Array(headers['Set-Cookie'] || headers['set-cookie']).each do |cookie|
      expect(cookie.downcase).to include('secure', 'httponly', 'samesite=lax')
    end
  end
end
