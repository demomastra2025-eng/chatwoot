ActiveRecordQueryTrace.enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch('ACTIVE_RECORD_QUERY_TRACE', 'false')) if Rails.env.development?
