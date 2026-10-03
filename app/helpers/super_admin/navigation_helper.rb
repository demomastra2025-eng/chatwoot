module SuperAdmin::NavigationHelper
  def settings_open?
    params[:controller].in? %w[super_admin/settings super_admin/app_configs]
  end

  def super_admin_resource_label(resource)
    resource_name = resource.respond_to?(:resource) ? resource.resource.to_s : resource.to_s

    labels = {
      'accounts' => I18n.t('super_admin.resources.accounts', default: 'Аккаунты'),
      'account' => I18n.t('super_admin.resources.account', default: 'Аккаунт'),
      'users' => I18n.t('super_admin.resources.users', default: 'Пользователи'),
      'user' => I18n.t('super_admin.resources.user', default: 'Пользователь'),
      'platform_apps' => I18n.t('super_admin.resources.platform_apps', default: 'Платформенные приложения'),
      'platform_app' => I18n.t('super_admin.resources.platform_app', default: 'Платформенное приложение'),
      'platform_banners' => I18n.t('super_admin.resources.platform_banners', default: 'Баннеры платформы'),
      'platform_banner' => I18n.t('super_admin.resources.platform_banner', default: 'Баннер платформы'),
      'agent_bots' => I18n.t('super_admin.resources.agent_bots', default: 'AI-боты'),
      'agent_bot' => I18n.t('super_admin.resources.agent_bot', default: 'AI-бот')
    }
    return labels[resource_name] if labels.key?(resource_name)

    model_name = resource_name.singularize.classify.safe_constantize&.model_name
    return model_name.human(count: 2) if model_name.present?

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
    'captain' => 'Captain AI',
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
    'captain' => 'Управление AI-ассистентами, LLM-моделями и автоответами для клиентов.',
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

  def feature_label(attrs)
    key = attrs['config_key'] || attrs[:config_key]
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
