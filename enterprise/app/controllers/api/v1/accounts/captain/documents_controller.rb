class Api::V1::Accounts::Captain::DocumentsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_current_page, only: [:index]
  before_action :set_documents, except: [:create, :preview]
  before_action :set_document, only: [:show, :destroy, :resync, :refresh_changed_only, :retry_failed]
  before_action :set_assistant, only: [:create, :preview]
  RESULTS_PER_PAGE = 25

  def index
    base_query = @documents.source_documents
    base_query = base_query.where(assistant_id: permitted_params[:assistant_id]) if permitted_params[:assistant_id].present?

    @documents_count = base_query.count
    @documents = base_query.page(@current_page).per(RESULTS_PER_PAGE)
  end

  def show; end

  def create
    return render_could_not_create_error(I18n.t('captain.documents.missing_assistant')) if @assistant.nil?
    return render_could_not_create_error(missing_firecrawl_error) if firecrawl_required_for_mode?(requested_source_mode)

    @document = @assistant.documents.build(base_document_params)
    @document.metadata = document_metadata
    @document.save!
  rescue Captain::Document::LimitExceededError => e
    render_could_not_create_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  end

  def preview
    return render_could_not_create_error(I18n.t('captain.documents.missing_assistant')) if @assistant.nil?

    root_url = document_creation_params[:external_link].presence
    return render_could_not_create_error(I18n.t('captain.documents.missing_root_url')) if root_url.blank?

    links = if Captain::Tools::FirecrawlService.configured?
              preview_links_from_firecrawl(root_url)
            else
              Captain::Tools::SimplePageCrawlService.new(root_url).page_links.to_a
            end

    render json: {
      payload: normalize_preview_links(links)
    }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def resync
    return render_could_not_create_error(I18n.t('captain.documents.derived_document_resync_error')) if @document.derived_document?
    return render_could_not_create_error(missing_firecrawl_error) if firecrawl_required_for_mode?(@document.source_mode)

    @document.prepare_for_resync!(refresh_mode: 'full')
    Captain::Documents::CrawlJob.perform_later(@document)
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def refresh_changed_only
    return render_could_not_create_error(I18n.t('captain.documents.derived_document_sync_error')) if @document.derived_document?
    return render_could_not_create_error(I18n.t('captain.documents.delta_refresh_uploaded_file_error')) if %w[pdf_upload
                                                                                                              file_upload].include?(@document.source_mode)
    return render_could_not_create_error(missing_firecrawl_error) if firecrawl_required_for_mode?(@document.source_mode)

    @document.prepare_for_resync!(refresh_mode: 'delta')
    Captain::Documents::CrawlJob.perform_later(@document)
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def retry_failed
    return render_could_not_create_error(I18n.t('captain.documents.derived_document_retry_error')) if @document.derived_document?
    return render_could_not_create_error(I18n.t('captain.documents.retry_failed_empty_error')) if @document.failed_urls.blank?
    return render_could_not_create_error(missing_firecrawl_error) if firecrawl_required_for_mode?(@document.source_mode)

    @document.prepare_for_resync!(refresh_mode: 'retry_failed')
    Captain::Documents::CrawlJob.perform_later(@document)
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def destroy
    @document.destroy
    head :no_content
  end

  private

  def set_documents
    @documents = Current.account.captain_documents.includes(:assistant).ordered
  end

  def set_document
    @document = @documents.find(permitted_params[:id])
  end

  def set_assistant
    @assistant = Current.account.captain_assistants.find_by(id: document_creation_params[:assistant_id])
  end

  def set_current_page
    @current_page = permitted_params[:page] || 1
  end

  def permitted_params
    params.permit(:assistant_id, :page, :id, :account_id)
  end

  def base_document_params
    document_creation_params.slice(:name, :external_link, :assistant_id, :pdf_file, :source_file, :faq_generation_enabled)
  end

  def document_creation_params
    @document_creation_params ||= params.require(:document).permit(
      :name,
      :external_link,
      :assistant_id,
      :pdf_file,
      :source_file,
      :source_mode,
      :faq_generation_enabled,
      import_profile: [:sitemap, :max_pages, :max_discovery_depth, :allow_subdomains, :ignore_query_parameters, :only_main_content,
                       { include_paths: [], exclude_paths: [] }],
      selected_urls: []
    )
  end

  def document_metadata
    return {} if requested_source_mode == 'pdf_upload'

    source_mode = requested_source_mode

    {
      'firecrawl' => {
        'provider' => Captain::Tools::FirecrawlService.configured? ? 'firecrawl' : 'simple_crawl',
        'mode' => source_mode,
        'source_document' => true,
        'root_url' => document_creation_params[:external_link],
        'selected_urls' => Array(document_creation_params[:selected_urls]),
        'import_profile' => sanitized_import_profile,
        'sync' => initial_sync_state(source_mode)
      }
    }
  end

  def initial_sync_state(source_mode)
    pages_total = document_creation_params[:selected_urls]&.size if source_mode == 'selected_pages'

    {
      'status' => 'queued',
      'pages_total' => pages_total,
      'pages_processed' => 0,
      'processed_urls' => [],
      'last_error' => nil
    }.compact
  end

  def sanitized_import_profile
    profile = document_creation_params[:import_profile]&.to_h || {}
    {
      'sitemap' => profile['sitemap'].presence || 'include',
      'max_pages' => profile['max_pages'].presence&.to_i,
      'max_discovery_depth' => profile['max_discovery_depth'].presence&.to_i,
      'allow_subdomains' => ActiveModel::Type::Boolean.new.cast(profile['allow_subdomains']),
      'ignore_query_parameters' => boolean_or_default(profile['ignore_query_parameters'], true),
      'only_main_content' => boolean_or_default(profile['only_main_content'], true),
      'include_paths' => Array(profile['include_paths']).reject(&:blank?),
      'exclude_paths' => Array(profile['exclude_paths']).reject(&:blank?)
    }.compact
  end

  def preview_links_from_firecrawl(root_url)
    response = Captain::Tools::FirecrawlService.new.map(root_url, preview_map_options)
    parsed_response = response.parsed_response
    return parsed_response if parsed_response.is_a?(Array)

    parsed_response['links'] || parsed_response['data'] || []
  end

  def preview_map_options
    profile = sanitized_import_profile

    {
      sitemap: profile['sitemap'],
      allow_subdomains: profile['allow_subdomains'],
      ignore_query_parameters: profile['ignore_query_parameters'],
      limit: profile['max_pages'] || 100
    }
  end

  def normalize_preview_links(links)
    Array(links)
      .map do |entry|
        item = entry.is_a?(Hash) ? entry.with_indifferent_access : { url: entry.to_s }
        next if item[:url].blank?

        {
          url: item[:url].to_s.delete_suffix('/'),
          title: item[:title].to_s,
          description: item[:description].to_s
        }
      end
      .compact
      .uniq { |item| item[:url] }
      .sort_by { |item| item[:url] }
  end

  def boolean_or_default(value, default)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def requested_source_mode
    return 'pdf_upload' if document_creation_params[:pdf_file].present?
    return 'file_upload' if document_creation_params[:source_file].present?

    document_creation_params[:source_mode].presence || Captain::Document::DEFAULT_SOURCE_MODE
  end

  def firecrawl_required_for_mode?(source_mode)
    %w[pdf_url file_url file_upload].include?(source_mode.to_s) && !Captain::Tools::FirecrawlService.configured?
  end

  def missing_firecrawl_error
    I18n.t('captain.documents.missing_firecrawl_error')
  end
end
