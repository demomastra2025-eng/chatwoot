module SuperAdmin::NavigationHelper
  # The settings group is open on the instance settings page and on every
  # config page except the AI models one, which has its own sidebar entry.
  def settings_open?
    super_admin_nav_active?(:settings) || (super_admin_nav_active?(:app_configs) && !super_admin_ai_models_page?)
  end

  # The "Модели ИИ" page is the `captain` config page of the app config.
  def super_admin_ai_models_page? = super_admin_nav_active?(:app_configs) && params[:config].to_s == 'captain'

  # True when the current request is served by one of the given controllers
  # (names relative to the namespace, e.g. `:accounts` for super_admin/accounts).
  # Used to mark the current sidebar entry, so nested pages (show, edit, new)
  # keep their section highlighted.
  def super_admin_nav_active?(*controllers) = controllers.map { |name| "super_admin/#{name}" }.include?(params[:controller])

  # Label of the environment badge in the sidebar. Production shows nothing.
  def super_admin_environment_label
    return if Rails.env.production?

    Rails.env.upcase
  end

  # The names of the resources in the sidebar and in the titles; the Russian text of each is in `super_admin.resources`
  RESOURCE_LABELS = {
    'organizations' => 'Организации', 'organization' => 'Организация', 'accounts' => 'Аккаунты', 'account' => 'Аккаунт',
    'users' => 'Пользователи', 'user' => 'Пользователь', 'platform_apps' => 'Доступ по API для партнёров',
    'platform_app' => 'Партнёрский доступ', 'platform_banners' => 'Баннеры платформы',
    'platform_banner' => 'Баннер платформы'
  }.freeze

  def super_admin_resource_label(resource)
    resource_name = resource.respond_to?(:resource) ? resource.resource.to_s : resource.to_s
    return I18n.t("super_admin.resources.#{resource_name}", default: RESOURCE_LABELS[resource_name]) if RESOURCE_LABELS.key?(resource_name)

    model_name = resource_name.singularize.classify.safe_constantize&.model_name
    # the plural of the name (Administrate asks for it the same way): a fraction takes the `other` form of every language
    return model_name.human(count: Administrate::ApplicationHelper::PLURAL_MANY_COUNT) if model_name.present?

    resource_name.tr('/', ' ').tr('_', ' ').titleize
  end

  FEATURE_LABELS = {
    'general' => 'Общие параметры',
    'saml' => 'SAML SSO',
    'custom_branding' => 'Брендирование',
    'agent_capacity' => 'Лимиты операторов',
    'audit_logs' => 'Журнал аудита',
    'disable_branding' => 'Отключение копирайта',
    'help_center' => 'База знаний',
    'captain' => 'Модели ИИ',
    'live_chat' => 'Онлайн-чат',
    'email' => 'Электронная почта',
    'sms' => 'SMS',
    'facebook' => 'Facebook & Messenger',
    'instagram' => 'Instagram',
    'tiktok' => 'TikTok',
    'whatsapp' => 'WhatsApp',
    'telegram' => 'Telegram',
    'line' => 'Line',
    'google' => 'Google OAuth',
    'microsoft' => 'Microsoft Office 365',
    'linear' => 'Linear',
    'notion' => 'Notion',
    'slack' => 'Slack',
    'whatsapp_embedded' => 'WhatsApp Embedded',
    'shopify' => 'Shopify'
  }.freeze

  FEATURE_DESCRIPTIONS = {
    'saml' => 'Управление единым входом (SSO) через корпоративный протокол SAML.',
    'custom_branding' => 'Настройка фирменного стиля, логотипов и кастомизации платформы.',
    'agent_capacity' => 'Ограничения автоматического распределения диалогов по операторам.',
    'audit_logs' => 'Отслеживание и детальный журнал действий пользователей и администраторов.',
    'disable_branding' => 'Скрытие копирайта и водяных знаков OneLink в виджете чата и письмах.',
    'help_center' => 'Создание базы знаний и публичных порталов справочной информации.',
    'captain' => 'Модели ИИ-агентов, ключи OpenRouter и системные промпты платформы.',
    'live_chat' => 'Интерактивный виджет онлайн-чата на сайте для взаимодействия с клиентами.',
    'email' => 'Подключение почтовых ящиков и обработка входящих обращений по Email.',
    'sms' => 'Интеграция SMS-сообщений для оперативной связи и уведомлений клиентов.',
    'facebook' => 'Подключение страниц Facebook и сообщений Facebook Messenger.',
    'instagram' => 'Интеграция Direct и комментариев Instagram для работы операторов.',
    'tiktok' => 'Обработка сообщений и лидов из бизнес-аккаунта TikTok.',
    'whatsapp' => 'Интеграция бизнес-номеров WhatsApp для общения с клиентами.',
    'telegram' => 'Подключение ботов Telegram для обработки входящих обращений.',
    'line' => 'Интеграция с азиатским мессенджером Line.',
    'google' => 'Настройка авторизации пользователей через Google OAuth.',
    'microsoft' => 'Настройка интеграции с корпоративной почтой Microsoft Office 365.',
    'linear' => 'Интеграция с системой управления задачами Linear.',
    'notion' => 'Интеграция с рабочими пространствами и страницами Notion.',
    'slack' => 'Интеграция со Slack для уведомлений и операторов.',
    'whatsapp_embedded' => 'Быстрое подключение WhatsApp Cloud API (Embedded Signup).',
    'shopify' => 'Интеграция с заказами и клиентами интернет-магазина Shopify.'
  }.freeze

  # attrs: an entry of features.yml. A function without a config page is looked up by its own key (live_chat, sms).
  def feature_label(attrs, feature_key = nil)
    key = attrs['config_key'] || attrs[:config_key] || feature_key.to_s
    FEATURE_LABELS[key] || attrs['name'] || attrs[:name]
  end

  def feature_description(feature_key, attrs)
    key = attrs['config_key'] || attrs[:config_key] || feature_key.to_s
    FEATURE_DESCRIPTIONS[key] || attrs['description'] || attrs[:description]
  end

  def settings_pages
    enabled_features = SuperAdmin::FeaturesHelper.available_features.select do |_feature, attrs|
      attrs['config_key'].present? && attrs['enabled']
    end

    features = enabled_features.transform_values do |attrs|
      localized_name = FEATURE_LABELS[attrs['config_key']] || attrs['name']
      attrs.merge('name' => localized_name)
    end

    # Add general at the beginning
    general_feature = [['general', { 'config_key' => 'general', 'name' => I18n.t('super_admin.settings.general', default: 'Общие параметры') }]]

    general_feature + features.to_a
  end
end
