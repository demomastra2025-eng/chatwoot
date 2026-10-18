class Api::V1::Accounts::Scheduling::ProductsController < Api::V1::Accounts::Scheduling::BaseController
  PERMITTED_SCALAR_PARAMS = %i[name item_type code article category uom description price wholesale_price kaspi_price buy_price min_price
                               currency stock reserve in_transit quantity active].freeze

  skip_before_action :ensure_scheduling_enabled!
  before_action :check_admin_authorization?, except: [:index, :show, :moysklad_status]
  before_action :set_product, only: [:show, :update, :destroy]

  rescue_from Integrations::Moysklad::ApiClient::ApiError, with: :render_moysklad_error

  def index
    products = filtered_products

    render_payload(
      products.map { |product| Scheduling::PayloadBuilder.product(product) },
      meta: {
        count: products.size,
        moysklad: moysklad_status_payload(moysklad_hook)
      }
    )
  end

  def show
    render_payload(Scheduling::PayloadBuilder.product(@product))
  end

  def create
    product = Current.account.scheduling_products.create!(product_params)
    render_payload(Scheduling::PayloadBuilder.product(product), status: :created)
  end

  def update
    @product.update!(product_params)
    render_payload(Scheduling::PayloadBuilder.product(@product.reload))
  end

  def destroy
    @product.destroy!
    head :no_content
  end

  def moysklad_status
    render_payload(moysklad_status_payload(moysklad_hook))
  end

  def moysklad_config
    hook = upsert_moysklad_hook!
    render_payload(moysklad_status_payload(hook))
  end

  def sync_moysklad
    hook = resolve_sync_hook
    return render_moysklad_not_configured if hook.blank?

    summary = Integrations::Moysklad::ProductsSyncService.new(
      account: Current.account,
      hook: hook,
      price_type_name: params[:price_type_name]
    ).perform
    products = Current.account.scheduling_products.ordered

    render_payload(
      products.map { |product| Scheduling::PayloadBuilder.product(product) },
      meta: { count: products.size, sync_summary: summary, moysklad: moysklad_status_payload(hook.reload) }
    )
  end

  private

  def resolve_sync_hook
    if params[:access_token].present? || params[:login].present? || params[:price_type_name].present?
      upsert_moysklad_hook!
    else
      moysklad_hook
    end
  end

  def render_moysklad_not_configured
    render_error(
      code: 'MOYSKLAD_NOT_CONFIGURED',
      error: 'Интеграция с МойСклад не настроена. Укажите API-токен или логин и пароль.',
      status: :unprocessable_content
    )
  end

  def filtered_products
    scope = Current.account.scheduling_products.ordered
    scope = scope.active unless parse_boolean(params[:include_inactive])
    scope = apply_exact_filters(scope)
    apply_search_filter(scope)
  end

  def apply_exact_filters(scope)
    scope = scope.where(item_type: params[:item_type]) if params[:item_type].present?
    scope = scope.where(category: params[:category]) if params[:category].present?
    scope = scope.where(external_source: params[:external_source]) if params[:external_source].present?
    scope
  end

  def apply_search_filter(scope)
    return scope if params[:q].blank?

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
    scope.where(
      'name ILIKE :q OR code ILIKE :q OR article ILIKE :q OR category ILIKE :q OR description ILIKE :q',
      q: pattern
    )
  end

  def set_product
    @product = Current.account.scheduling_products.find(params[:id])
  end

  def product_params
    permitted = params.permit(
      *PERMITTED_SCALAR_PARAMS,
      barcodes: {},
      characteristics: [:id, :name, :value],
      sale_prices: [:id, :name, :value],
      store_stocks: [:store_id, :store_name, :stock, :reserve, :in_transit, :available],
      custom_attributes: {}
    )

    normalize_integer_numeric_params!(permitted, :price, :buy_price, :min_price)
    normalize_integer_numeric_params!(permitted, :wholesale_price) if permitted[:wholesale_price].present?
    normalize_integer_numeric_params!(permitted, :kaspi_price) if permitted[:kaspi_price].present?
    permitted
  end

  def moysklad_hook
    Current.account.hooks.find_by(app_id: 'moysklad')
  end

  def upsert_moysklad_hook!
    hook = Current.account.hooks.find_or_initialize_by(app_id: 'moysklad')
    assign_moysklad_hook_token!(hook)
    assign_moysklad_hook_settings!(hook)
    hook.save!
    hook
  end

  def assign_moysklad_hook_token!(hook)
    token = resolve_incoming_moysklad_token
    if token.present?
      hook.access_token = token
    elsif hook.new_record?
      raise ArgumentError, 'access_token is required'
    end
  end

  def resolve_incoming_moysklad_token
    token = params[:access_token].to_s.strip.presence
    return token if token.present?
    return nil unless params[:login].present? && params[:password].present?

    Integrations::Moysklad::ApiClient.exchange_credentials_for_token!(
      login: params[:login],
      password: params[:password]
    )
  end

  def assign_moysklad_hook_settings!(hook)
    current_settings = hook.settings.is_a?(Hash) ? hook.settings.deep_dup : {}
    incoming_price = params[:price_type_name].to_s.strip.presence if params.key?(:price_type_name)
    current_settings['price_type_name'] = incoming_price || current_settings['price_type_name'].presence || 'Цена продажи'
    hook.settings = current_settings
    hook.status = parse_boolean(params[:enabled], default: true) ? 'enabled' : 'disabled'
  end

  def moysklad_status_payload(hook)
    count = Current.account.scheduling_products.where(external_source: 'moysklad').count
    return disconnected_moysklad_payload(count) if hook.blank?

    settings = hook.settings.is_a?(Hash) ? hook.settings : {}
    {
      connected: true,
      status: hook.status,
      hook_id: hook.id,
      price_type_name: settings['price_type_name'].presence || 'Цена продажи',
      masked_token: mask_moysklad_token(hook),
      last_synced_at: settings['last_synced_at'],
      last_sync_summary: settings['last_sync_summary'],
      synced_products_count: count
    }
  end

  def disconnected_moysklad_payload(count)
    {
      connected: false,
      status: 'disabled',
      hook_id: nil,
      price_type_name: 'Цена продажи',
      masked_token: nil,
      last_synced_at: nil,
      last_sync_summary: nil,
      synced_products_count: count
    }
  end

  def mask_moysklad_token(hook)
    raw = hook.secret_settings['api_token'].presence || hook.access_token.to_s
    return "#{raw[0, 4]}••••#{raw[-4, 4]}" if raw.length > 8

    raw.present? ? '••••••••' : nil
  end

  def render_moysklad_error(error)
    render_error(code: error.code, error: error.message, details: error.details, status: error.status)
  end
end
