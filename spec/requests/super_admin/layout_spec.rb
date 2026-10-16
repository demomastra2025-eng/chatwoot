require 'rails_helper'

RSpec.describe 'Super Admin layout and login page', type: :request do
  let(:super_admin) { create(:super_admin, password: 'Password1!') }
  let(:page) { Nokogiri::HTML(response.body) }

  # The first <head> child that loads CSS or JS from a file.
  def first_asset_index(head)
    head.element_children.index do |node|
      (node.name == 'link' && node['rel'] == 'stylesheet') || (node.name == 'script' && node['src'].present?)
    end
  end

  def theme_script_index(head)
    head.element_children.index { |node| node.name == 'script' && node['src'].blank? && node.text.include?('color_scheme') }
  end

  describe 'navigation of signed-in pages' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'gives the logo explicit width and height so it never renders at its natural size' do
      get '/super_admin/users'

      logo = page.at_css('[role="navigation"] img')
      expect(logo).to be_present
      expect(logo['src']).to include('/brand-assets/logo_thumbnail.svg')
      expect(logo['width']).to eq('39')
      expect(logo['height']).to eq('32')
    end

    it 'declares Russian and the design-system body classes' do
      get '/super_admin/users'

      expect(page.at_css('html')['lang']).to eq('ru')
      expect(page.at_css('body')['class'].split).to include('bg-n-background', 'text-n-slate-12', 'antialiased')
    end

    it 'applies the theme in <head> before any stylesheet or script file' do
      get '/super_admin/users'

      head = page.at_css('head')
      expect(theme_script_index(head)).to be_present
      expect(theme_script_index(head)).to be < first_asset_index(head)
      script = head.element_children[theme_script_index(head)].text
      expect(script).to include("'color_scheme'", 'prefers-color-scheme', "classList.add('dark')", 'colorScheme')
    end

    it 'does not load the Vue bundle on pages that do not need it' do
      get '/super_admin/users'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('superadmin_pages')
    end

    it 'loads the Vue bundle in <head> on the dashboard and keeps its mount point' do
      get '/super_admin'

      expect(response).to have_http_status(:ok)
      expect(page.at_css('head script[src*="superadmin_pages"]')).to be_present
      expect(page.at_css('#app[data-component-name="DashboardIndex"]')).to be_present
    end
  end

  # The sprockets Administrate stylesheet is still linked because gem field
  # partials emit its class names. The super admin bundle restyles that markup on
  # the design tokens (light and dark); it is loaded after the sprockets sheet.
  describe 'restyle of the Administrate stylesheet' do
    let(:scss_dir) { Rails.root.join('app/javascript/dashboard/assets/scss/super_admin') }
    let(:index_scss) { File.read(scss_dir.join('index.scss')) }
    let(:admin_scss) { File.read(scss_dir.join('_admin.scss')) }

    it 'is imported after the Tailwind layers by the super admin stylesheet' do
      expect(index_scss).to include("@import './admin';")
      expect(index_scss.index('tailwindcss/utilities')).to be < index_scss.index("'./admin'")
    end

    it 'takes over the page, buttons, tables, show page, forms, flashes, pagination and search' do
      expect(admin_scss).to include(
        '.main-content__header', '.main-content__body', '.admin-card', 'tbody tr:hover', '.attribute-list', '.attribute-label',
        '.field-unit', '.form-actions', '.flash-notice', '.pagination', '.search__eyeglass-icon', 'a:hover'
      )
    end

    it 'does not offset the page content by the absolute Administrate column' do
      expect(admin_scss).to match(/\.main-content \{[^}]*position: static;/m)
    end

    it 'repeats the gem button selectors so that the restyle wins over their specificity' do
      expect(admin_scss).to include(
        "'button:not(.reset-base)'", "'input[type=\"submit\"]:not(.reset-base)'", "'.button:not(.reset-base)'",
        '.button.button--secondary:not(.reset-base)', '.button.button--alt:not(.reset-base)', '.button.button--danger:not(.reset-base)'
      )
    end

    it 'covers every field selector that Administrate paints white' do
      forms = File.read(Rails.root.join('app/assets/stylesheets/administrate/base/_forms.scss'))
      painted = forms[/\[type="color"\].*?textarea \{/m].scan(/\[type="[a-z-]+"\]|input:not\(\[type\]\)|textarea/).uniq

      expect(painted).not_to be_empty
      painted.each { |selector| expect(admin_scss).to include(selector) }
    end

    it 'uses design tokens instead of fixed colours' do
      expect(admin_scss).not_to match(/#[0-9a-fA-F]{3,8}\b|rgba?\(\s*\d/)
    end

    it 'has no literal white: the danger label and the checkbox tick use the brand contrast token' do
      expect(admin_scss).not_to match(/(?:text|bg|border|outline)-white|stroke=['"]white['"]|:\s*white\b/)
      expect(admin_scss).to include('.button.button--danger:not(.reset-base)', 'rgb(var(--brand-contrast))')
      expect(admin_scss).to match(/\.button--danger:not\(\.reset-base\) \{\s*@apply bg-n-ruby-9 text-n-brand-contrast;/)
    end

    it 'draws the secret field buttons as quiet icon buttons, without a brand fill on hover' do
      block = admin_scss[/\.cell-data__secret-field \{.*?\n  \}\n/m]

      expect(block).to include('[data-secret-toggler]', '[data-secret-copier]', 'bg-transparent', 'hover')
      expect(block).not_to include('brand-solid')
    end

    it 'quiets the table switch of a chart here, in a rule scoped to the super admin, not in the shared component' do
      block = admin_scss[/button\[data-test-id='ds-chart-table-toggle'\]:not\(\.reset-base\) \{.*?^  \}$/m]
      component = File.read(Rails.root.join('app/javascript/dashboard/components-next/ds/DsChartFrame.vue'))

      expect(block).to include('bg-transparent', 'text-n-slate-11', 'transform: none', '&:hover')
      expect(block).not_to include('brand-solid')
      expect(component).to include('data-test-id="ds-chart-table-toggle"')
      expect(component[/<button[^>]*ds-chart-table-toggle[^>]*>/m]).not_to include('reset-base')
    end

    it 'defines the blocks of the clinic card on tokens only' do
      clinic_scss = File.read(scss_dir.join('_clinic.scss'))

      expect(index_scss).to include("@import './clinic';")
      expect(clinic_scss).to include(
        '.admin-block', '.admin-badge', '.admin-meter', '.admin-switch', '.admin-collapse', '.admin-plan-card', '.admin-kv'
      )
      expect(clinic_scss).not_to match(/#[0-9a-fA-F]{3,8}\b|rgba?\(\s*\d|\bwhite\b/)
    end

    it 'leaves no hard-coded select chevron colour behind' do
      stylesheets = Dir[Rails.root.join('app/javascript/dashboard/assets/scss/super_admin/*.scss'), Rails.root.join('app/views/super_admin/**/*.erb')]

      expect(stylesheets.map { |path| File.read(path) }.join).not_to include('23293f54')
    end
  end

  describe 'flash messages markup' do
    it 'tells nobody to mark flash text as html_safe' do
      partial = File.read(Rails.root.join('app/views/super_admin/application/_flashes.html.erb'))

      expect(partial).not_to include('html_safe')
    end
  end

  describe 'GET /super_admin/sign_in' do
    before { get '/super_admin/sign_in' }

    it 'renders exactly one logo image with explicit width and height' do
      images = page.css('img')

      expect(images.size).to eq(1)
      expect(images.first['src']).to include('/brand-assets/logo')
      expect(images.first['width']).to be_present
      expect(images.first['height']).to be_present
    end

    it 'is a complete Russian document with charset and viewport' do
      expect(page.at_css('html')['lang']).to eq('ru')
      expect(page.at_css('meta[charset]')).to be_present
      expect(page.at_css('meta[name="viewport"]')).to be_present
    end

    it 'applies the theme in <head> before any stylesheet or script file' do
      head = page.at_css('head')

      expect(theme_script_index(head)).to be_present
      expect(theme_script_index(head)).to be < first_asset_index(head)
    end

    it 'posts to the session route and has the Russian copy' do
      form = page.at_css('form')

      expect(form['action']).to eq(super_admin_session_path)
      expect(form['method']).to eq('post')
      expect(page.at_css('input[type="email"][name="super_admin[email]"]')).to be_present
      expect(page.at_css('input[type="password"][name="super_admin[password]"]')).to be_present
      expect(response.body).to include('Вход в супер-админку', 'Только для администраторов платформы OneLink', 'E-mail', 'Пароль', 'Войти')
    end

    it 'labels the fields so they can be focused by their label' do
      %w[super_admin_email super_admin_password].each do |id|
        expect(page.at_css("label[for=\"#{id}\"]")).to be_present
        expect(page.at_css("##{id}")).to be_present
      end
    end

    it 'uses design-system tokens instead of the legacy palette and has no emoji' do
      expect(response.body).to include('bg-n-brand-solid')
      expect(response.body).not_to match(/\b(?:bg|text|ring|border)-(?:woot|slate|gray)-\d/)
      expect(response.body).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
    end
  end

  describe 'POST /super_admin/sign_in' do
    it 'sends a signed-in admin to the dashboard' do
      post '/super_admin/sign_in', params: { super_admin: { email: super_admin.email, password: 'Password1!' } }

      expect(response).to redirect_to(super_admin_root_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#app[data-component-name="DashboardIndex"]')).to be_present
    end

    it 'shows a failed sign-in as an alert on the login page' do
      post '/super_admin/sign_in', params: { super_admin: { email: super_admin.email, password: 'nope' } }
      follow_redirect!

      alert = page.at_css('[role="alert"]')
      expect(alert).to be_present
      expect(alert.text.strip).to be_present
      expect(alert.text).not_to include('%{')
      expect(alert['class']).to include('text-n-ruby-11')
    end
  end
end
