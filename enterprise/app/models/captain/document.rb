# == Schema Information
#
# Table name: captain_documents
#
#  id                     :bigint           not null, primary key
#  content                :text
#  external_link          :string           not null
#  faq_generation_enabled :boolean          default(TRUE), not null
#  metadata               :jsonb
#  name                   :string
#  source_text            :text
#  status                 :integer          default("in_progress"), not null
#  visibility             :integer          default("general"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  assistant_id           :bigint
#
# Indexes
#
#  idx_captain_documents_account_visibility                 (account_id,visibility)
#  index_captain_documents_on_account_id                    (account_id)
#  index_captain_documents_on_account_id_and_external_link  (account_id,external_link) UNIQUE
#  index_captain_documents_on_assistant_id                  (assistant_id)
#  index_captain_documents_on_status                        (status)
#
class Captain::Document < ApplicationRecord
  class LimitExceededError < StandardError; end
  class InvalidSourceModeError < StandardError; end
  class ImportJobMismatchError < StandardError; end
  self.table_name = 'captain_documents'
  include AccountStorageLimitable

  DEFAULT_SOURCE_MODE = 'legacy_url'.freeze
  SOURCE_MODES = %w[legacy_url single_page site_import selected_pages pdf_url file_url file_upload pdf_upload].freeze
  FILE_PREFIX = 'FILE:'.freeze
  PDF_PREFIX = 'PDF:'.freeze
  TEXT_DOCUMENT_EXTENSIONS = %w[txt text md markdown csv json xml yaml yml].freeze
  FIRECRAWL_DOCUMENT_EXTENSIONS = %w[pdf docx doc odt rtf xlsx xls html htm].freeze
  SUPPORTED_REMOTE_FILE_EXTENSIONS = (
    TEXT_DOCUMENT_EXTENSIONS + %w[docx doc odt rtf xlsx xls html htm]
  ).freeze
  SUPPORTED_IMAGE_EXTENSIONS = %w[jpg jpeg png webp gif heic heif tiff tif bmp].freeze
  SUPPORTED_UPLOAD_EXTENSIONS = (
    FIRECRAWL_DOCUMENT_EXTENSIONS + TEXT_DOCUMENT_EXTENSIONS + SUPPORTED_IMAGE_EXTENSIONS
  ).uniq.freeze

  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :destroy, as: :documentable
  has_many :document_chunks, class_name: 'Captain::DocumentChunk', dependent: :destroy, inverse_of: :document
  belongs_to :account
  has_one_attached :pdf_file
  has_one_attached :source_file
  account_storage_attachments :pdf_file, :source_file

  validates :external_link, presence: true, unless: :uploaded_file_attached?
  validates :external_link, uniqueness: { scope: :account_id }, allow_blank: true
  validates :content, length: { maximum: 200_000 }
  validates :pdf_file, presence: true, if: :pdf_upload?
  validate :validate_pdf_format, if: :pdf_upload?
  validate :validate_uploaded_source_file_format, if: -> { source_file.attached? }
  validate :validate_remote_source_url, if: :remote_source_mode?
  validate :assistant_belongs_to_account
  before_validation :ensure_account_id
  before_validation :set_external_link_for_pdf
  before_validation :set_external_link_for_uploaded_file
  before_validation :normalize_external_link

  enum status: {
    in_progress: 0,
    available: 1,
    failed: 2
  }
  enum visibility: { general: 0, personal: 1 }, _prefix: :visibility

  before_create :ensure_within_plan_limit
  after_create_commit :enqueue_crawl_job
  after_create_commit :update_document_usage
  after_destroy :update_document_usage
  after_destroy_commit :destroy_derived_documents
  after_commit :enqueue_response_builder_job
  scope :ordered, -> { order(created_at: :desc) }

  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :for_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }
  # assistant_id nil is workspace-owned knowledge. These rows can be general or
  # workspace-personal, but they are not assistant-private records.
  scope :workspace_owned, -> { where(assistant_id: nil) }
  scope :visible_to_assistant, lambda { |assistant_id|
    if assistant_id.blank?
      workspace_owned
    else
      where(
        <<~SQL.squish,
          captain_documents.assistant_id IS NULL OR
          captain_documents.visibility = :general_visibility OR
          captain_documents.assistant_id = :assistant_id
        SQL
        general_visibility: visibilities[:general],
        assistant_id: assistant_id
      )
    end
  }
  scope :source_documents, lambda {
    where("COALESCE(metadata -> 'firecrawl' ->> 'root_document_id', '') = ''")
  }

  def pdf_document?
    pdf_upload? || remote_pdf_url?
  end

  def pdf_upload?
    pdf_file.attached? && pdf_file.blob.content_type == 'application/pdf'
  end

  def file_upload?
    source_file.attached?
  end

  def image_upload?
    source_file.attached? && SUPPORTED_IMAGE_EXTENSIONS.include?(uploaded_source_extension)
  end

  def text_source_upload?
    source_file.attached? && TEXT_DOCUMENT_EXTENSIONS.include?(uploaded_source_extension)
  end

  def remote_pdf_url?
    remote_document_extension == 'pdf'
  end

  def remote_file_url?
    SUPPORTED_REMOTE_FILE_EXTENSIONS.include?(remote_document_extension)
  end

  def remote_html_file_url?
    %w[html htm].include?(remote_document_extension)
  end

  def source_pdf_upload?
    source_file.attached? && uploaded_source_extension == 'pdf'
  end

  def remote_document_extension
    return if external_link.blank?

    path = URI.parse(external_link).path.presence || external_link
    File.extname(path).delete_prefix('.').downcase.presence
  rescue URI::InvalidURIError
    nil
  end

  def content_type
    uploaded_file_attachment&.blob&.content_type
  end

  def file_size
    uploaded_file_attachment&.blob&.byte_size
  end

  def sendable_file?
    available? && uploaded_file_attachment.present? && uploaded_file_attachment.attached?
  end

  def sendable_filename
    uploaded_file_attachment&.blob&.filename&.to_s
  end

  def sendable_file_signed_id
    return unless sendable_file?

    uploaded_file_attachment.blob.signed_id
  end

  def sendable_file_blob_id
    return unless sendable_file?

    uploaded_file_attachment.blob_id
  end

  def artifact_fingerprint
    updated_at&.to_i&.to_s
  end

  def faq_generation_text
    source_text.presence || content
  end

  def faq_generation_text_present?
    faq_generation_text.present?
  end

  def source_text_metadata
    metadata&.dig('source_text') || {}
  end

  def firecrawl_metadata
    metadata&.dig('firecrawl') || {}
  end

  def firecrawl_sync
    firecrawl_metadata['sync'] || {}
  end

  def current_import_run_id
    firecrawl_sync['import_run_id']
  end

  def import_job_id
    firecrawl_metadata['job_id']
  end

  def received_urls
    Array(firecrawl_sync['received_urls'])
  end

  def source_mode
    return 'pdf_upload' if pdf_upload?
    return 'file_upload' if file_upload?

    firecrawl_metadata['mode'].presence || DEFAULT_SOURCE_MODE
  end

  def validate_import_source_mode!
    mode = source_mode
    raise InvalidSourceModeError, I18n.t('captain.documents.invalid_source_mode') unless SOURCE_MODES.include?(mode)

    missing_upload = (mode == 'file_upload' && !file_upload?) || (mode == 'pdf_upload' && !pdf_upload?)
    raise InvalidSourceModeError, I18n.t('captain.documents.missing_upload_file') if missing_upload

    true
  end

  def expected_import_url?(page_url)
    return true unless refresh_mode == 'retry_failed'

    retry_urls.include?(normalize_import_url(page_url))
  end

  def source_document?
    firecrawl_metadata['root_document_id'].blank?
  end

  def derived_document?
    !source_document?
  end

  def import_profile
    firecrawl_metadata['import_profile'] || {}
  end

  def selected_urls
    firecrawl_metadata['selected_urls'] || []
  end

  def sync_status
    return firecrawl_sync['status'] if firecrawl_sync['status'].present?

    return 'failed' if failed?
    return 'completed' if available?

    'processing'
  end

  def pages_processed
    firecrawl_sync['pages_processed'].to_i
  end

  def pages_total
    total = firecrawl_sync['pages_total']
    total.present? ? total.to_i : nil
  end

  def selected_urls_count
    selected_urls.count
  end

  def failed_urls
    Array(firecrawl_sync['failed_urls'])
  end

  def retry_urls
    Array(firecrawl_sync['retry_urls'])
  end

  def failed_urls_count
    failed_urls.count
  end

  def refresh_mode
    firecrawl_sync['refresh_mode'].presence || 'full'
  end

  def last_error
    firecrawl_sync['last_error']
  end

  def last_synced_at
    raw_value = firecrawl_sync['last_synced_at']
    return if raw_value.blank?

    Time.zone.parse(raw_value)
  rescue ArgumentError, TypeError
    nil
  end

  def self.embedding_status_summaries_for(documents)
    document_ids = Array(documents).filter_map(&:id)
    return {} if document_ids.blank?

    summaries = document_ids.index_with { empty_embedding_status_summary }
    chunk_status_counts(document_ids).each do |(document_id, status), count|
      status_name = embedding_status_name(status)
      next if status_name.blank?

      summaries[document_id][status_name.to_sym] = count
    end

    latest_failed_embedding_errors(document_ids).each do |document_id, error|
      summaries[document_id][:last_error] ||= error
    end

    summaries.transform_values do |summary|
      summary[:total] = summary.values_at(:indexed, :pending, :failed, :stale).sum
      summary[:degraded] = summary.values_at(:pending, :failed, :stale).sum.positive?
      summary
    end
  end

  def self.empty_embedding_status_summary
    {
      total: 0,
      indexed: 0,
      pending: 0,
      failed: 0,
      stale: 0,
      degraded: false,
      last_error: nil
    }
  end

  def embedding_status_summary
    self.class.embedding_status_summaries_for([self]).fetch(id, self.class.empty_embedding_status_summary)
  end

  def merge_metadata!(attributes)
    update!(metadata: merged_metadata(attributes))
  end

  def prepare_for_resync!(refresh_mode: 'full')
    retry_targets = refresh_mode == 'retry_failed' ? failed_urls : []
    sync_attributes = resync_sync_attributes(refresh_mode, retry_targets)
    updated_metadata = (metadata || {}).deep_dup
    updated_metadata['firecrawl'] = firecrawl_metadata.except('job_id').merge('sync' => sync_attributes)
    update!(status: :in_progress, metadata: updated_metadata)
  end

  def ensure_import_run_id!
    run_id = nil
    with_lock do
      reload
      run_id = current_import_run_id
      next if run_id.present?

      run_id = SecureRandom.uuid
      update!(
        metadata: merged_metadata(
          'firecrawl' => firecrawl_metadata.deep_merge(
            'sync' => firecrawl_sync.merge('import_run_id' => run_id)
          )
        )
      )
    end
    run_id
  end

  def current_import_run?(import_run_id = current_import_run_id)
    import_run_id.to_s == current_import_run_id.to_s
  end

  def with_current_import_run(import_run_id = current_import_run_id)
    applied = false
    with_lock do
      reload
      next unless current_import_run?(import_run_id)

      yield self
      applied = true
    end
    applied
  end

  def with_active_import_run(import_run_id = current_import_run_id)
    applied = false
    with_lock do
      reload
      next unless current_import_run?(import_run_id)
      next if terminal_import?

      yield self
      applied = true
    end
    applied
  end

  def mark_import_processing!(import_run_id: current_import_run_id)
    with_current_import_run(import_run_id) do
      next if terminal_import?

      update!(
        metadata: merged_metadata(
          'firecrawl' => firecrawl_metadata.deep_merge(
            'sync' => firecrawl_sync.merge('status' => 'processing', 'last_error' => nil)
          )
        )
      )
    end
  end

  def mark_import_started!(job_id: nil, pages_total: nil, import_run_id: current_import_run_id)
    with_current_import_run(import_run_id) do
      next if terminal_import?

      ensure_import_job_matches!(job_id)

      sync_updates = {
        'status' => 'processing',
        'import_run_id' => import_run_id,
        'last_error' => nil
      }
      sync_updates['pages_total'] = pages_total if pages_total.present?

      firecrawl_updates = {
        'sync' => firecrawl_sync.merge(sync_updates)
      }
      firecrawl_updates['job_id'] = job_id if job_id.present?

      update!(
        metadata: merged_metadata(
          'firecrawl' => firecrawl_metadata.deep_merge(firecrawl_updates)
        )
      )
    end
  end

  def mark_import_completed!(failed_urls: nil, import_run_id: current_import_run_id)
    with_current_import_run(import_run_id) do
      next if terminal_import?

      apply_import_completed!(failed_urls)
    end
  end

  def finalize_import!(failed_urls: nil, import_run_id: current_import_run_id)
    result = :stale
    with_current_import_run(import_run_id) do
      if terminal_import?
        result = :terminal
        next
      end

      if pending_import_pages?
        result = :pending
        next
      end

      apply_import_completed!(failed_urls)
      result = :completed
    end
    result
  end

  def fail_import_if_pending!(error_message, import_run_id: current_import_run_id)
    result = :stale
    with_current_import_run(import_run_id) do
      if terminal_import?
        result = :terminal
      elsif pending_import_pages?
        apply_import_failed!(error_message)
        result = :failed
      else
        result = :resolved
      end
    end
    result
  end

  def mark_import_failed!(error_message, import_run_id: current_import_run_id)
    with_current_import_run(import_run_id) do
      next if terminal_import?

      apply_import_failed!(error_message)
    end
  end

  def mark_page_received!(page_url, import_run_id: current_import_run_id)
    return false unless source_document?

    normalized_url = normalize_import_url(page_url)
    return false if normalized_url.blank?

    with_current_import_run(import_run_id) do
      next if terminal_import?

      received = (received_urls + [normalized_url]).uniq
      update_import_sync!(firecrawl_sync.merge('received_urls' => received))
    end
  end

  def process_import_page!(page_url, change_status: nil, import_run_id: current_import_run_id)
    return false unless source_document?

    normalized_url = normalize_import_url(page_url)
    return false if normalized_url.blank?

    with_active_import_run(import_run_id) do
      yield self if block_given?
      updated_sync = firecrawl_sync
      updated_sync = sync_with_change_result(updated_sync, normalized_url, change_status) if change_status.present?
      update_import_sync!(processed_import_sync(updated_sync, normalized_url))
    end
  end

  def mark_page_processed!(page_url, import_run_id: current_import_run_id)
    process_import_page!(page_url, import_run_id: import_run_id)
  end

  def record_failed_urls!(urls, import_run_id: current_import_run_id)
    normalized_urls = Array(urls).filter_map { |url| normalize_import_url(url) }.uniq
    return false if normalized_urls.blank?

    with_current_import_run(import_run_id) do
      next if terminal_import?

      failed = (failed_urls + normalized_urls).uniq
      received = (received_urls + normalized_urls).uniq
      updated_sync = progress_sync(firecrawl_sync.merge('received_urls' => received, 'failed_urls' => failed))
      update_import_sync!(updated_sync)
    end
  end

  def pending_import_pages?
    resolved_urls = resolved_import_urls(firecrawl_sync)
    if refresh_mode == 'retry_failed'
      expected_urls = retry_urls
      return (expected_urls - resolved_urls).any?
    end
    return true if (received_urls - resolved_urls).any?

    pages_total.present? && resolved_urls.size < pages_total
  end

  def record_change_result!(page_url, change_status, import_run_id: current_import_run_id)
    normalized_url = page_url.to_s.delete_suffix('/')
    bucket = case change_status.to_s
             when 'same' then 'same_urls'
             when 'removed' then 'removed_urls'
             else 'changed_urls'
             end

    with_current_import_run(import_run_id) do
      next if terminal_import?

      current_urls = Array(firecrawl_sync[bucket])
      next if current_urls.include?(normalized_url)

      current_urls << normalized_url
      update!(
        metadata: merged_metadata(
          'firecrawl' => firecrawl_metadata.deep_merge(
            'sync' => firecrawl_sync.merge(bucket => current_urls)
          )
        )
      )
    end
  end

  def display_url
    return Rails.application.routes.url_helpers.rails_blob_url(uploaded_file_attachment.blob, only_path: false) if uploaded_file_attached?

    external_link
  end

  def runtime_assistant
    assistant ||
      account&.captain_assistants&.external_agent&.ordered&.first ||
      account&.captain_assistants&.ordered&.first
  end

  def runtime_assistant_id
    runtime_assistant&.id
  end

  private

  def terminal_import?
    %w[completed failed].include?(firecrawl_sync['status'])
  end

  def ensure_import_job_matches!(job_id)
    return if job_id.blank? || import_job_id.blank? || import_job_id.to_s == job_id.to_s

    raise ImportJobMismatchError, 'Firecrawl job ID does not match the active import'
  end

  def processed_import_sync(sync, normalized_url)
    processed = (Array(sync['processed_urls']) + [normalized_url]).uniq
    failed = Array(sync['failed_urls']) - [normalized_url]
    received = (Array(sync['received_urls']) + [normalized_url]).uniq
    progress_sync(
      sync.merge(
        'received_urls' => received,
        'processed_urls' => processed,
        'failed_urls' => failed,
        'pages_processed' => processed.size
      )
    )
  end

  def sync_with_change_result(sync, normalized_url, change_status)
    bucket = case change_status.to_s
             when 'same' then 'same_urls'
             when 'removed' then 'removed_urls'
             else 'changed_urls'
             end
    sync.merge(bucket => (Array(sync[bucket]) + [normalized_url]).uniq)
  end

  def resync_sync_attributes(refresh_mode, retry_targets)
    attributes = {
      'status' => 'queued',
      'import_run_id' => SecureRandom.uuid,
      'pages_processed' => 0,
      'processed_urls' => [],
      'received_urls' => [],
      'last_error' => nil,
      'refresh_mode' => refresh_mode,
      'changed_urls' => [],
      'same_urls' => [],
      'removed_urls' => [],
      'retry_urls' => retry_targets,
      'failed_urls' => []
    }
    pages_total = refresh_mode == 'retry_failed' ? retry_targets.count : selected_urls_count
    attributes['pages_total'] = pages_total if pages_total.positive?
    attributes
  end

  def apply_import_completed!(reported_failed_urls)
    merged_failed_urls = (failed_urls + Array(reported_failed_urls)).uniq
    updated_sync = firecrawl_sync.merge(
      'status' => 'completed',
      'last_synced_at' => Time.current.iso8601,
      'last_error' => nil,
      'failed_urls' => merged_failed_urls
    )

    update!(
      status: :available,
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge(
          'sync' => updated_sync
        )
      )
    )
  end

  def apply_import_failed!(error_message)
    update!(
      status: :failed,
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge(
          'sync' => firecrawl_sync.merge(
            'status' => 'failed',
            'last_error' => error_message.to_s,
            'last_synced_at' => Time.current.iso8601
          )
        )
      )
    )
  end

  def normalize_import_url(value)
    value.to_s.delete_suffix('/').presence
  end

  def progress_sync(sync)
    updated_sync = sync.merge('status' => 'processing')
    resolved_count = resolved_import_urls(sync).size
    return updated_sync unless pages_total.present? && resolved_count >= pages_total
    return updated_sync if import_job_id.present?

    updated_sync.merge(
      'status' => 'completed',
      'last_synced_at' => Time.current.iso8601
    )
  end

  def resolved_import_urls(sync)
    resolved_urls = (Array(sync['processed_urls']) + Array(sync['failed_urls'])).uniq
    return resolved_urls unless refresh_mode == 'retry_failed'

    resolved_urls & retry_urls
  end

  def update_import_sync!(sync)
    update!(
      status: (sync['status'] == 'completed' ? :available : status),
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge('sync' => sync)
      )
    )
  end

  def uploaded_file_attachment
    return source_file if source_file.attached?
    return pdf_file if pdf_file.attached?

    nil
  end

  def uploaded_file_attached?
    uploaded_file_attachment.present?
  end

  def uploaded_source_extension
    return unless source_file.attached?

    source_file.filename.extension_without_delimiter&.downcase
  end

  def merged_metadata(attributes)
    (metadata || {}).deep_merge(attributes)
  end

  def enqueue_crawl_job
    return if status != 'in_progress'

    Captain::Documents::CrawlJob.perform_later(self)
  end

  def enqueue_response_builder_job
    return unless should_enqueue_response_builder?

    Captain::Documents::ResponseBuilderJob.perform_later(self)
  end

  def should_enqueue_response_builder?
    return false if destroyed?
    return false unless available?
    return false unless faq_generation_enabled?

    return saved_change_to_status? || saved_change_to_source_text? || saved_change_to_faq_generation_enabled? if pdf_upload?
    return false unless faq_generation_text_present?

    saved_change_to_status? || saved_change_to_content? || saved_change_to_source_text? || saved_change_to_faq_generation_enabled?
  end

  def self.chunk_status_counts(document_ids)
    Captain::DocumentChunk.where(document_id: document_ids).group(:document_id, :embedding_status).count
  end

  def self.latest_failed_embedding_errors(document_ids)
    Captain::DocumentChunk
      .where(document_id: document_ids, embedding_status: Captain::DocumentChunk.embedding_statuses[:failed])
      .where.not(embedding_error: [nil, ''])
      .order(embedding_updated_at: :desc, updated_at: :desc)
      .pluck(:document_id, :embedding_error)
      .each_with_object({}) do |(document_id, error), memo|
        memo[document_id] ||= error
      end
  end

  def self.embedding_status_name(status)
    return status if Captain::DocumentChunk.embedding_statuses.key?(status.to_s)

    Captain::DocumentChunk.embedding_statuses.key(status.to_i)
  end

  private_class_method :chunk_status_counts, :latest_failed_embedding_errors, :embedding_status_name

  def update_document_usage
    account.update_document_usage
  end

  def ensure_account_id
    self.account_id ||= assistant&.account_id
  end

  def assistant_belongs_to_account
    return if assistant.blank? || account_id.blank? || assistant.account_id == account_id

    errors.add(:assistant, 'must belong to the same account')
  end

  def ensure_within_plan_limit
    limits = account.usage_limits.dig(:captain, :documents) || {}
    return if limits[:unlimited]

    Account.lock.find(account_id)
    current_count = Captain::Document.where(account_id: account_id).count
    within_limit = if limits[:total_count].present?
                     current_count < limits[:total_count].to_i
                   else
                     limits[:current_available].to_i.positive?
                   end
    raise LimitExceededError, I18n.t('captain.documents.limit_exceeded') unless within_limit
  end

  def validate_pdf_format
    return unless pdf_file.attached?

    errors.add(:pdf_file, I18n.t('captain.documents.pdf_format_error')) unless pdf_file.blob.content_type == 'application/pdf'
  end

  def validate_uploaded_source_file_format
    return unless source_file.attached?

    return if SUPPORTED_UPLOAD_EXTENSIONS.include?(uploaded_source_extension)

    errors.add(:source_file, I18n.t('captain.documents.file_upload_format_error'))
  end

  def validate_remote_source_url
    return if external_link.blank?
    return if remote_document_extension.blank?

    case source_mode
    when 'pdf_url'
      return if remote_pdf_url?

      errors.add(:external_link, I18n.t('captain.documents.remote_pdf_url_error'))
    when 'file_url'
      return if remote_file_url?

      errors.add(:external_link, I18n.t('captain.documents.remote_file_url_error'))
    end
  end

  def set_external_link_for_pdf
    return unless pdf_file.attached? && external_link.blank?

    # Set a unique external_link for PDF files
    # Format: PDF: filename_timestamp (without extension)
    timestamp = Time.current.strftime('%Y%m%d%H%M%S')
    self.external_link = "#{PDF_PREFIX} #{pdf_file.filename.base}_#{timestamp}"
  end

  def set_external_link_for_uploaded_file
    return unless source_file.attached? && external_link.blank?

    timestamp = Time.current.strftime('%Y%m%d%H%M%S')
    extension = uploaded_source_extension.presence || 'file'
    self.external_link = "#{FILE_PREFIX} #{source_file.filename.base}_#{timestamp}.#{extension}"
  end

  def normalize_external_link
    return if external_link.blank?
    return if uploaded_file_attached?

    self.external_link = external_link.delete_suffix('/')
  end

  def destroy_derived_documents
    return unless source_document?

    self.class
        .where(account_id: account_id)
        .where("metadata -> 'firecrawl' ->> 'root_document_id' = ?", id.to_s)
        .find_each(&:destroy!)
  end

  def remote_source_mode?
    %w[pdf_url file_url].include?(source_mode)
  end
end
