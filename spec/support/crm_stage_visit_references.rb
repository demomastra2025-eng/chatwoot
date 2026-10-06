# crm_stage_visits.pipeline_id and stage_id are NOT NULL unless the table was created or relaxed with nullable
# references. This context makes them nullable inside the example's transaction (DDL is transactional in PostgreSQL)
# so the "keep the history, clear the link" deletion policy can be exercised; without it the specs run on the
# schema.rb shape, where a pipeline or stage with visits is refused with *_HAS_HISTORY.
RSpec.shared_context 'with detachable crm stage visit references' do
  before do
    connection = ActiveRecord::Base.connection
    connection.execute('ALTER TABLE crm_stage_visits ALTER COLUMN pipeline_id DROP NOT NULL')
    connection.execute('ALTER TABLE crm_stage_visits ALTER COLUMN stage_id DROP NOT NULL')
    reset_crm_stage_visit_columns
  end

  def after_teardown
    super
  ensure
    # Rails has rolled the DDL back by now: forget the nullable column information.
    reset_crm_stage_visit_columns
  end

  def reset_crm_stage_visit_columns
    connection = ActiveRecord::Base.connection
    connection.clear_cache!
    connection.schema_cache.clear_data_source_cache!('crm_stage_visits')
    Crm::StageVisit.reset_column_information
  end
end
