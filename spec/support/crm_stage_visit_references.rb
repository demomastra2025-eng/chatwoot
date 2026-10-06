# crm_stage_visits.pipeline_id and stage_id are created nullable (ON DELETE SET NULL) by the table creation migration,
# which is the shape of schema.rb. A database that already had the table in its older NOT NULL shape (the aset
# lineage) keeps that shape, and the deletion rules answer 422 *_HAS_HISTORY there instead of a database error.
# These contexts put the example's transaction into one shape or the other (DDL is transactional in PostgreSQL), so both
# policies stay covered whatever the schema is.
module CrmStageVisitReferenceShape
  def alter_crm_stage_visit_references(change)
    connection = ActiveRecord::Base.connection
    %w[pipeline_id stage_id].each do |column|
      connection.execute("ALTER TABLE crm_stage_visits ALTER COLUMN #{column} #{change}")
    end
    reset_crm_stage_visit_columns
  end

  def after_teardown
    super
  ensure
    # Rails has rolled the DDL back by now: forget the changed column information.
    reset_crm_stage_visit_columns
  end

  def reset_crm_stage_visit_columns
    connection = ActiveRecord::Base.connection
    connection.clear_cache!
    connection.schema_cache.clear_data_source_cache!('crm_stage_visits')
    Crm::StageVisit.reset_column_information
  end
end

# The "keep the history, clear the link" deletion policy: the references accept NULL.
RSpec.shared_context 'with detachable crm stage visit references' do
  include CrmStageVisitReferenceShape

  before { alter_crm_stage_visit_references('DROP NOT NULL') }
end

# The older shape: the references are NOT NULL, so a pipeline or stage with visits cannot be detached.
RSpec.shared_context 'with required crm stage visit references' do
  include CrmStageVisitReferenceShape

  before { alter_crm_stage_visit_references('SET NOT NULL') }
end
