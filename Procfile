release: POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare && echo $SOURCE_VERSION > .git_sha
web: bundle exec rails ip_lookup:setup && bin/rails server -p $PORT -e $RAILS_ENV
worker: ENABLE_SIDEKIQ_CRON=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq.yml
whatsapp_inbound_worker: ENABLE_SIDEKIQ_CRON=false DISABLE_SIDEKIQ_ALIVE=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq_whatsapp_inbound.yml
audio_transcription_worker: ENABLE_SIDEKIQ_CRON=false DISABLE_SIDEKIQ_ALIVE=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq_audio_transcription.yml
telegram_personal_history_worker: ENABLE_SIDEKIQ_CRON=false DISABLE_SIDEKIQ_ALIVE=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq_telegram_personal_history.yml
history_worker: ENABLE_SIDEKIQ_CRON=false DISABLE_SIDEKIQ_ALIVE=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq_whatsappweb_history.yml
echo_worker: ENABLE_SIDEKIQ_CRON=false DISABLE_SIDEKIQ_ALIVE=true bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq_whatsappweb_echo.yml
