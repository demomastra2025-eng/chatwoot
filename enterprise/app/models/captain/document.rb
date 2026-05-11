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
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  assistant_id           :bigint           not null
#
# Indexes
#
#  index_captain_documents_on_account_id                      (account_id)
#  index_captain_documents_on_assistant_id                    (assistant_id)
#  index_captain_documents_on_assistant_id_and_external_link  (assistant_id,external_link) UNIQUE
#  index_captain_documents_on_status                          (status)
#
class Captain::Document < ApplicationRecord
  class LimitExceededError < StandardError; end
  self.table_name = 'captain_documents'
  include AccountStorageLimitable

  DEFAULT_SOURCE_MODE = 'legacy_url'.freeze
  FILE_PREFIX = 'FILE:'.freeze
  PDF_PREFIX = 'PDF:'.freeze
  MAX_UPLOAD_SIZE = 40.megabytes
  SUPPORTED_REMOTE_FILE_EXTENSIONS = %w[
    docx doc odt rtf xlsx xls csv txt md markdown html htm xml json yaml yml pptx ppt odp ods epub
  ].freeze
  SUPPORTED_IMAGE_EXTENSIONS = %w[jpg jpeg png webp gif heic heif tiff tif bmp].freeze
  SUPPORTED_UPLOAD_EXTENSIONS = (SUPPORTED_REMOTE_FILE_EXTENSIONS + SUPPORTED_IMAGE_EXTENSIONS).freeze

  belongs_to :assistant, class_name: 'Captain::Assistant'
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :destroy, as: :documentable
  belongs_to :account
  has_one_attached :pdf_file
  has_one_attached :source_file
  account_storage_attachments :pdf_file, :source_file

  validates :external_link, presence: true, unless: :uploaded_file_attached?
  validates :external_link, uniqueness: { scope: :assistant_id }, allow_blank: true
  validates :content, length: { maximum: 200_000 }
  validates :pdf_file, presence: true, if: :pdf_upload?
  validate :validate_pdf_format, if: :pdf_upload?
  validate :validate_pdf_attachment_size, if: :pdf_upload?
  validate :validate_uploaded_source_file_format, if: -> { source_file.attached? }
  validate :validate_uploaded_source_file_size, if: -> { source_file.attached? }
  validate :validate_remote_source_url, if: :remote_source_mode?
  before_validation :ensure_account_id
  before_validation :set_external_link_for_pdf
  before_validation :set_external_link_for_uploaded_file
  before_validation :normalize_external_link

  enum status: {
    in_progress: 0,
    available: 1,
    failed: 2
  }

  before_create :ensure_within_plan_limit
  after_create_commit :enqueue_crawl_job
  after_create_commit :update_document_usage
  after_destroy :update_document_usage
  after_destroy_commit :destroy_derived_documents
  after_commit :enqueue_response_builder_job
  scope :ordered, -> { order(created_at: :desc) }

  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :for_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }
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

  def remote_pdf_url?
    remote_document_extension == 'pdf'
  end

  def remote_file_url?
    SUPPORTED_REMOTE_FILE_EXTENSIONS.include?(remote_document_extension)
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

  def source_mode
    return 'pdf_upload' if pdf_upload?
    return 'file_upload' if file_upload?

    firecrawl_metadata['mode'].presence || DEFAULT_SOURCE_MODE
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

  def merge_metadata!(attributes)
    update!(metadata: merged_metadata(attributes))
  end

  def prepare_for_resync!(refresh_mode: 'full')
    sync_attributes = {
      'status' => 'queued',
      'pages_processed' => 0,
      'processed_urls' => [],
      'last_error' => nil,
      'refresh_mode' => refresh_mode,
      'changed_urls' => [],
      'same_urls' => [],
      'removed_urls' => []
    }
    pages_total = if refresh_mode == 'retry_failed'
                    failed_urls_count
                  else
                    selected_urls_count
                  end
    sync_attributes['pages_total'] = pages_total if pages_total.positive?
    sync_attributes['failed_urls'] = [] if refresh_mode == 'full'

    update!(
      status: :in_progress,
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge('sync' => sync_attributes)
      )
    )
  end

  def mark_import_processing!
    update!(
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge(
          'sync' => firecrawl_sync.merge('status' => 'processing', 'last_error' => nil)
        )
      )
    )
  end

  def mark_import_started!(job_id: nil, pages_total: nil)
    sync_updates = {
      'status' => 'processing',
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

  def mark_import_completed!(failed_urls: nil)
    updated_sync = firecrawl_sync.merge(
      'status' => 'completed',
      'last_synced_at' => Time.current.iso8601,
      'last_error' => nil
    )
    updated_sync['failed_urls'] = Array(failed_urls) unless failed_urls.nil?

    update!(
      status: :available,
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge(
          'sync' => updated_sync
        )
      )
    )
  end

  def mark_import_failed!(error_message)
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

  def mark_page_processed!(page_url)
    return unless source_document?

    normalized_url = page_url.to_s.delete_suffix('/')

    with_lock do
      processed_urls = Array(firecrawl_sync['processed_urls'])
      return if processed_urls.include?(normalized_url)

      processed_urls << normalized_url
      updated_sync = firecrawl_sync.merge(
        'status' => 'processing',
        'processed_urls' => processed_urls,
        'pages_processed' => processed_urls.size
      )

      if pages_total.present? && processed_urls.size >= pages_total
        updated_sync['status'] = 'completed'
        updated_sync['last_synced_at'] = Time.current.iso8601
      end

      update!(
        status: (updated_sync['status'] == 'completed' ? :available : status),
        metadata: merged_metadata(
          'firecrawl' => firecrawl_metadata.deep_merge('sync' => updated_sync)
        )
      )
    end
  end

  def record_failed_urls!(urls)
    unique_urls = (failed_urls + Array(urls))
                  .map { |url| url.to_s.delete_suffix('/') }
                  .reject(&:blank?)
                  .uniq

    update!(
      metadata: merged_metadata(
        'firecrawl' => firecrawl_metadata.deep_merge(
          'sync' => firecrawl_sync.merge('failed_urls' => unique_urls)
        )
      )
    )
  end

  def record_change_result!(page_url, change_status)
    normalized_url = page_url.to_s.delete_suffix('/')
    bucket = case change_status.to_s
             when 'same' then 'same_urls'
             when 'removed' then 'removed_urls'
             else 'changed_urls'
             end

    with_lock do
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

  private

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

  def update_document_usage
    account.update_document_usage
  end

  def ensure_account_id
    self.account_id = assistant&.account_id
  end

  def ensure_within_plan_limit
    limits = account.usage_limits[:captain][:documents]
    raise LimitExceededError, I18n.t('captain.documents.limit_exceeded') unless limits[:current_available].positive?
  end

  def validate_pdf_format
    return unless pdf_file.attached?

    errors.add(:pdf_file, I18n.t('captain.documents.pdf_format_error')) unless pdf_file.blob.content_type == 'application/pdf'
  end

  def validate_pdf_attachment_size
    return unless pdf_file.attached?

    return unless pdf_file.blob.byte_size > MAX_UPLOAD_SIZE

    errors.add(:pdf_file, I18n.t('captain.documents.pdf_size_error'))
  end

  def validate_uploaded_source_file_format
    return unless source_file.attached?

    return if SUPPORTED_UPLOAD_EXTENSIONS.include?(uploaded_source_extension)

    errors.add(:source_file, I18n.t('captain.documents.file_upload_format_error'))
  end

  def validate_uploaded_source_file_size
    return unless source_file.attached?
    return unless source_file.blob.byte_size > MAX_UPLOAD_SIZE

    errors.add(:source_file, I18n.t('captain.documents.file_size_error'))
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
        .where(account_id: account_id, assistant_id: assistant_id)
        .where("metadata -> 'firecrawl' ->> 'root_document_id' = ?", id.to_s)
        .find_each(&:destroy!)
  end

  def remote_source_mode?
    %w[pdf_url file_url].include?(source_mode)
  end
end
