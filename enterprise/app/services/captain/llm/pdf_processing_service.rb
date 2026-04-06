class Captain::Llm::PdfProcessingService
  include Integrations::LlmInstrumentation

  def initialize(document)
    @document = document
  end

  def process
    raise CustomExceptions::Pdf::UploadError, I18n.t('captain.documents.pdf_upload_failed') unless document.pdf_file.attached?

    with_tempfile do |temp_file|
      instrument_file_prepare do
        raise CustomExceptions::Pdf::UploadError, I18n.t('captain.documents.pdf_upload_failed') if temp_file.size.to_i <= 0
      end
    end

    true
  end

  private

  attr_reader :document

  def instrument_file_prepare(&)
    return yield unless ChatwootApp.otel_enabled?

    tracer.in_span('llm.file.prepare') do |span|
      span.set_attribute('gen_ai.provider', 'local')
      span.set_attribute('file.purpose', 'knowledge_ingestion')
      span.set_attribute(ATTR_LANGFUSE_USER_ID, document.account_id.to_s)
      span.set_attribute(ATTR_LANGFUSE_TAGS, ['pdf_prepare'].to_json)
      span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'document_id'), document.id.to_s)
      yield
    end
  end

  def with_tempfile
    Tempfile.create(['pdf_upload', '.pdf'], binmode: true) do |temp_file|
      document.pdf_file.blob.open do |blob_file|
        IO.copy_stream(blob_file, temp_file)
      end

      temp_file.flush
      temp_file.rewind

      yield temp_file
    end
  end
end
