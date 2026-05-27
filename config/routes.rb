Rails.application.routes.draw do
  # AUTH STARTS
  mount_devise_token_auth_for 'User', at: 'auth', controllers: {
    confirmations: 'devise_overrides/confirmations',
    passwords: 'devise_overrides/passwords',
    sessions: 'devise_overrides/sessions',
    token_validations: 'devise_overrides/token_validations',
    omniauth_callbacks: 'devise_overrides/omniauth_callbacks'
  }, via: [:get, :post]

  ## renders the frontend paths only if its not an api only server
  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('CW_API_ONLY_SERVER', false))
    root to: 'api#index'
  else
    root to: 'dashboard#index'

    get '/app', to: 'dashboard#index'
    get '/app/*params', to: 'dashboard#index'
    get '/app/accounts/:account_id/settings/inboxes/new/twitter', to: 'dashboard#index', as: 'app_new_twitter_inbox'
    get '/app/accounts/:account_id/settings/inboxes/new/microsoft', to: 'dashboard#index', as: 'app_new_microsoft_inbox'
    get '/app/accounts/:account_id/settings/inboxes/new/instagram', to: 'dashboard#index', as: 'app_new_instagram_inbox'
    get '/app/accounts/:account_id/settings/inboxes/new/tiktok', to: 'dashboard#index', as: 'app_new_tiktok_inbox'
    get '/app/accounts/:account_id/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_twitter_inbox_agents'
    get '/app/accounts/:account_id/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_email_inbox_agents'
    get '/app/accounts/:account_id/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_instagram_inbox_agents'
    get '/app/accounts/:account_id/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_tiktok_inbox_agents'
    get '/app/accounts/:account_id/settings/inboxes/:inbox_id', to: 'dashboard#index', as: 'app_instagram_inbox_settings'
    get '/app/accounts/:account_id/settings/inboxes/:inbox_id', to: 'dashboard#index', as: 'app_tiktok_inbox_settings'
    get '/app/accounts/:account_id/settings/inboxes/:inbox_id', to: 'dashboard#index', as: 'app_email_inbox_settings'

    resource :widget, only: [:show]
    namespace :survey do
      resources :responses, only: [:show]
    end
    resource :slack_uploads, only: [:show]
  end

  get '/legal/:locale/terms', to: 'legal#terms', as: :legal_terms
  get '/legal/:locale/privacy', to: 'legal#privacy', as: :legal_privacy
  get '/public/confirmation_requests/:token/:decision', to: 'public/confirmation_requests#show', as: :public_confirmation_request
  get '/captain/mcp_oauth/callback', to: 'captain/mcp_oauth#callback', as: :captain_mcp_oauth_callback

  get '/health', to: 'health#show'
  get '/api', to: 'api#index'
  namespace :api, defaults: { format: 'json' } do
    namespace :v1 do
      # ----------------------------------
      # start of account scoped api routes
      get 'accounts/:account_id/context_fields', to: 'accounts/context_fields#index'
      resources :accounts, only: [:create, :show, :update] do
        member do
          post :update_active_at
          get :cache_keys
          delete :logo
        end

        scope module: :accounts do
          namespace :actions do
            resource :contact_merge, only: [:create]
          end
          resource :bulk_actions, only: [:create]
          resources :bulk_action_runs, only: [:show]
          resources :agents, only: [:index, :create, :update, :destroy] do
            post :bulk_create, on: :collection
          end
          namespace :captain do
            resource :observability, only: [:show], controller: 'observability' do
              get :metrics
              get :release_check
              get :export
              resources :annotations, only: [:index, :create, :destroy], controller: 'observability_annotations'
            end
            resource :preferences, only: [:show, :update] do
              post :refresh_openrouter_models
            end
            resource :evaluations, only: [:show], controller: 'evaluations' do
              post :run
              get :run_status
              post :import_conversation
              post :run_dataset
              post :red_team
            end
            resources :assistants do
              member do
                patch :avatar
                delete :avatar
                post :playground
                get :prompt_preview
              end
              collection do
                get :tools
                get :context_fields
              end
              resources :inboxes, only: [:index, :create, :destroy], param: :inbox_id
              resources :scenarios
            end
            resources :assistant_responses
            resources :bulk_actions, only: [:create]
            resources :copilot_threads, only: [:index, :create] do
              resources :copilot_messages, only: [:index, :create]
            end
            resources :custom_tools do
              collection do
                post :test
              end
            end
            resources :mcp_servers do
              collection do
                post :test
              end
              member do
                get :surface
                post :read_resource
                post :fetch_resource_template
                post :fetch_prompt
                post :task_get
                post :task_result
                post :task_cancel
                post :oauth_start
                delete :oauth_disconnect
              end
            end
            resources :documents, only: [:index, :show, :create, :destroy] do
              collection do
                post :preview
              end
              member do
                get :source_text
                post :resync
                post :refresh_changed_only
                post :retry_failed
              end
            end
            resource :tasks, only: [], controller: 'tasks' do
              post :rewrite
              post :summarize
              post :reply_suggestion
              post :label_suggestion
              post :follow_up
            end
          end
          resource :saml_settings, only: [:show, :create, :update, :destroy]
          resources :agent_bots, only: [:index, :create, :show, :update, :destroy] do
            delete :avatar, on: :member
            post :reset_access_token, on: :member
            post :reset_secret, on: :member
          end
          resources :contact_inboxes, only: [] do
            collection do
              post :filter
            end
          end
          resources :assignable_agents, only: [:index]
          resource :audit_logs, only: [:show]
          resources :callbacks, only: [] do
            collection do
              post :register_facebook_page
              get :register_facebook_page
              post :facebook_pages
              post :reauthorize_page
            end
          end
          resources :canned_responses, only: [:index, :create, :update, :destroy]
          resources :touches, only: [:index, :show, :create, :update, :destroy] do
            post :approve, on: :member
            post :cancel, on: :member
          end
          resources :touch_plans, only: [:index, :show, :create, :update] do
            post :apply, on: :member
            post :archive, on: :member
          end
          resources :automation_rules, only: [:index, :create, :show, :update, :destroy] do
            post :clone
          end
          resources :macros, only: [:index, :create, :show, :update, :destroy] do
            post :execute, on: :member
          end
          resources :sla_policies, only: [:index, :create, :show, :update, :destroy]
          resources :custom_roles, only: [:index, :create, :show, :update, :destroy]
          resources :agent_capacity_policies, only: [:index, :create, :show, :update, :destroy] do
            scope module: :agent_capacity_policies do
              resources :users, only: [:index, :create, :destroy]
              resources :inbox_limits, only: [:create, :update, :destroy]
            end
          end
          resources :campaigns, only: [:index, :create, :show, :update, :destroy] do
            post :preview, on: :collection
            get :analytics, on: :member
            post :retry_failed, on: :member
            post :cancel, on: :member
            post :restart, on: :member
            post :resume, on: :member
          end
          resources :dashboard_apps, only: [:index, :show, :create, :update, :destroy]
          namespace :content do
            resource :connection, only: [:show, :update, :destroy], controller: 'connections' do
              post :test
            end
            resources :channels, only: [:index, :destroy] do
              get :oauth_url, on: :collection
              get :find_slot, on: :member
            end
            resources :posts, only: [:index, :create, :destroy] do
              member do
                patch :status
                get :missing
              end
            end
            resources :media, only: [:create] do
              post :upload_from_url, on: :collection
            end
            resources :analytics, only: [:index]
          end

          namespace :scheduling do
            resource :calendar, only: [:show], controller: 'calendar'
            resources :resources, only: [:index, :show, :create, :update, :destroy] do
              resource :work_rules, only: [:show, :update], controller: 'resource_work_rules'
              resource :break_rules, only: [:show, :update], controller: 'resource_break_rules'
            end
            resources :contacts, only: [:index, :create, :update]
            resources :services, only: [:index, :show, :create, :update, :destroy]
            resources :appointments, only: [:index, :show, :create, :update, :destroy] do
              post :cancel, on: :member
              resources :payments, only: [:create], controller: 'appointment_payments'
              delete :payments, on: :member, to: 'appointment_payments#destroy'
            end
            resources :payments, only: [:index]
            resources :expenses, only: [:index] do
              collection do
                post :pay_all
              end
              member do
                post :pay
              end
            end
            resources :holidays, only: [:index, :create, :update, :destroy]
            resources :workday_overrides, only: [:index, :create, :update, :destroy]
            resources :time_offs, only: [:index, :create, :update, :destroy]
          end
          namespace :crm do
            resources :pipelines, only: [:index, :show, :create, :update, :destroy] do
              resources :stages, only: [:create]
            end
            resources :stages, only: [:update, :destroy]
            resources :task_statuses, only: [:index, :create, :update, :destroy]
            resources :field_definitions, only: [:index, :create, :update, :destroy]
            resources :deals, only: [:index, :show, :create, :update] do
              scope module: :deals do
                resources :comments, only: [:index, :create, :update, :destroy]
              end
              member do
                get :timeline
                post :transition_stage
                post :archive
                post :unarchive
              end
            end
            resources :tasks, only: [:index, :show, :create, :update] do
              scope module: :tasks do
                resources :comments, only: [:index, :create, :update, :destroy]
              end
              member do
                get :timeline
                post :change_status
                post :archive
                post :unarchive
              end
            end
          end
          namespace :channels do
            resource :twilio_channel, only: [:create]
          end
          resources :conversations, only: [:index, :create, :show, :update, :destroy] do
            collection do
              get :meta
              get :search
              post :filter
            end
            scope module: :conversations do
              resources :messages, only: [:index, :create, :destroy, :update] do
                member do
                  post :translate
                  post :retry
                end
              end
              resources :assignments, only: [:create]
              resources :labels, only: [:create, :index]
              resource :participants, only: [:show, :create, :update, :destroy]
              resource :direct_uploads, only: [:create]
              resource :draft_messages, only: [:show, :update, :destroy]
            end
            member do
              post :mute
              post :unmute
              post :transcript
              post :toggle_status
              post :toggle_priority
              post :toggle_typing_status
              post :update_last_seen
              post :unread
              post :custom_attributes
              post :destroy_custom_attributes
              get :attachments
              get :inbox_assistant
              post :cancel_captain_response if ChatwootApp.enterprise?
              get :reporting_events if ChatwootApp.enterprise?
            end
          end

          resources :search, only: [:index] do
            collection do
              get :conversations
              get :messages
              get :contacts
              get :articles
            end
          end

          resources :companies, only: [:index, :show, :create, :update, :destroy] do
            collection do
              get :search
            end
          end
          resources :contacts, only: [:index, :show, :update, :create, :destroy] do
            collection do
              get :active
              get :search
              post :filter
              post :import
              post :export
            end
            member do
              get :contactable_inboxes
              post :destroy_custom_attributes
              delete :avatar
            end
            scope module: :contacts do
              resources :conversations, only: [:index]
              resources :contact_inboxes, only: [:create]
              resources :labels, only: [:create, :index]
              resources :notes
              get :attachments, to: 'attachments#index'
              post :call, on: :member, to: 'calls#create' if ChatwootApp.enterprise?
            end
          end
          resources :csat_survey_responses, only: [:index] do
            collection do
              get :metrics
              get :download
            end
            member do
              patch :update if ChatwootApp.enterprise?
            end
          end
          resources :applied_slas, only: [:index] do
            collection do
              get :metrics
              get :download
            end
          end
          resources :reporting_events, only: [:index] if ChatwootApp.enterprise?
          resources :custom_attribute_definitions, only: [:index, :show, :create, :update, :destroy]
          resources :custom_filters, only: [:index, :show, :create, :update, :destroy]
          resources :inboxes, only: [:index, :show, :create, :update, :destroy] do
            get :assignable_agents, on: :member
            get :campaigns, on: :member
            get :agent_bot, on: :member
            post :set_agent_bot, on: :member
            delete :avatar, on: :member
            post :sync_templates, on: :member
            get :health, on: :member
            post :register_webhook, on: :member
            post :reset_secret, on: :member
            post :refresh_whatsapp_web_qr, on: :member
            post :reconnect_whatsapp_web, on: :member
            post :disconnect_whatsapp_web, on: :member
            post :repair_whatsapp_web, on: :member
            get :whatsapp_web_diagnostics, on: :member
            post :telegram_personal_request_code, on: :member, to: 'telegram_personal_channels#request_code'
            post :telegram_personal_request_qr, on: :member, to: 'telegram_personal_channels#request_qr'
            post :telegram_personal_verify_code, on: :member, to: 'telegram_personal_channels#verify_code'
            post :telegram_personal_verify_password, on: :member, to: 'telegram_personal_channels#verify_password'
            post :telegram_personal_reconnect, on: :member, to: 'telegram_personal_channels#reconnect'
            post :telegram_personal_history_sync, on: :member, to: 'telegram_personal_channels#history_sync'
            post :telegram_personal_contacts_sync, on: :member, to: 'telegram_personal_channels#contacts_sync'
            post :telegram_personal_disconnect, on: :member, to: 'telegram_personal_channels#disconnect'
            get :telegram_personal_diagnostics, on: :member, to: 'telegram_personal_channels#diagnostics'
            post :weixin_request_qr, on: :member, to: 'weixin_channels#request_qr'
            post :weixin_reconnect, on: :member, to: 'weixin_channels#reconnect'
            post :weixin_disconnect, on: :member, to: 'weixin_channels#disconnect'
            get :weixin_diagnostics, on: :member, to: 'weixin_channels#diagnostics'
            if ChatwootApp.enterprise?
              resource :conference, only: %i[create destroy], controller: 'conference' do
                get :token, on: :member
              end
            end

            resource :csat_template, only: [:show, :create], controller: 'inbox_csat_templates' do
              post :analyze, on: :collection
            end

            resources :whatsapp_templates,
                      only: [:create, :destroy],
                      controller: 'inbox_whatsapp_templates',
                      param: :template_name
          end

          namespace :telephony do
            resources :calls, only: [:index, :show], param: :call_ref, constraints: { call_ref: %r{[^/]+} } do
              member do
                get :recording
              end

              collection do
                post :outbound
              end
            end

            get :capabilities, to: 'resources#capabilities'
            get 'resources/summary', to: 'resources#summary'
            get 'resources/readiness', to: 'resources#readiness'
            get :applications, to: 'resources#applications'
            get :numbers, to: 'resources#numbers'
            get 'numbers/:number_ref', to: 'resources#number'
            get :trunks, to: 'resources#trunks'
            get :agents, to: 'resources#agents'

            post 'numbers/:number_ref/route', to: 'routing#update'
            post 'agents/:agent_ref/enabled', to: 'agents#enabled'
            post 'ai/toggle', to: 'routing#toggle_ai'
            post 'webphone/token', to: 'webphone#create'
            post 'webphone/presence', to: 'webphone#presence'
            post 'webphone/claim', to: 'webphone#claim'
            post 'webphone/reject', to: 'webphone#reject'
          end

          resources :inbox_members, only: [:create, :show], param: :inbox_id do
            collection do
              delete :destroy
              patch :update
            end
          end
          resources :labels, only: [:index, :show, :create, :update, :destroy]

          resources :notifications, only: [:index, :update, :destroy] do
            collection do
              post :read_all
              get :unread_count
              post :destroy_all
            end
            member do
              post :snooze
              post :unread
            end
          end
          resource :notification_settings, only: [:show, :update] do
            delete :disconnect_telegram
          end

          resources :teams do
            resources :team_members, only: [:index, :create] do
              collection do
                delete :destroy
                patch :update
              end
            end
          end

          # Assignment V2 Routes
          resources :assignment_policies do
            resources :inboxes, only: [:index, :create, :destroy], module: :assignment_policies
          end

          resources :inboxes, only: [] do
            resource :assignment_policy, only: [:show, :create, :destroy], module: :inboxes
          end

          namespace :twitter do
            resource :authorization, only: [:create]
          end

          namespace :microsoft do
            resource :authorization, only: [:create]
          end

          namespace :google do
            resource :authorization, only: [:create]
          end

          namespace :instagram do
            resource :authorization, only: [:create]
          end

          namespace :tiktok do
            resource :authorization, only: [:create]
          end

          namespace :notion do
            resource :authorization, only: [:create]
          end

          namespace :whatsapp do
            resource :authorization, only: [:create]
          end

          resources :whatsapp_calls, only: [:show] do
            collection do
              get :active
              post :initiate
              post :prepare_outbound
            end
            member do
              post :accept
              post :reject
              post :terminate
              post :dial
              post :agent_answer
              post :reconnect
              post :join
              post :play_audio
              post :upload_recording
            end
          end

          resources :webhooks, only: [:index, :create, :update, :destroy]
          namespace :integrations do
            resources :apps, only: [:index, :show]
            resources :hooks, only: [:show, :create, :update, :destroy] do
              member do
                post :process_event
                post :run_sync
              end
            end
            resource :slack, only: [:create, :update, :destroy], controller: 'slack' do
              member do
                get :list_all_channels
              end
            end
            resource :dyte, controller: 'dyte', only: [] do
              collection do
                post :create_a_meeting
                post :add_participant_to_meeting
              end
            end
            resource :shopify, controller: 'shopify', only: [:destroy] do
              collection do
                post :auth
                get :orders
              end
            end
            resource :linear, controller: 'linear', only: [] do
              collection do
                delete :destroy
                get :teams
                get :team_entities
                post :create_issue
                post :link_issue
                post :unlink_issue
                get :search_issue
                get :linked_issues
              end
            end
            resource :notion, controller: 'notion', only: [] do
              collection do
                delete :destroy
              end
            end
            resource :kaspi_pay, controller: 'kaspi_pay', only: [:destroy] do
              collection do
                post 'auth/init', action: :init
                post 'auth/send_phone', action: :send_phone
                post 'auth/verify_otp', action: :verify_otp
              end
            end
          end
          namespace :kaspi_pay do
            resources :payments, only: [:create, :show] do
              post :refund, on: :member
            end
          end
          resources :working_hours, only: [:update]

          resources :portals do
            member do
              patch :archive
              delete :logo
              post :send_instructions
              get :ssl_status
            end
            resources :categories do
              post :reorder, on: :collection
            end
            resources :articles do
              post :reorder, on: :collection
            end
          end

          resources :upload, only: [:create]
        end
      end
      # end of account scoped api routes
      # ----------------------------------

      namespace :integrations do
        resources :webhooks, only: [:create]
      end

      # Frontend API endpoint to trigger SAML authentication flow
      post 'auth/saml_login', to: 'auth#saml_login'

      resource :profile, only: [:show, :update] do
        delete :avatar, on: :collection
        member do
          post :availability
          post :auto_offline
          put :set_active_account
          post :resend_confirmation
          post :reset_access_token
        end

        # MFA routes
        scope module: 'profile' do
          resource :mfa, controller: 'mfa', only: [:show, :create, :destroy] do
            post :verify
            post :backup_codes
          end
        end
      end

      resource :notification_subscriptions, only: [:create, :destroy]

      namespace :widget do
        resource :direct_uploads, only: [:create]
        resource :config, only: [:create]
        resources :campaigns, only: [:index]
        resources :events, only: [:create]
        resources :messages, only: [:index, :create, :update]
        resources :conversations, only: [:index, :create] do
          collection do
            post :destroy_custom_attributes
            post :set_custom_attributes
            post :update_last_seen
            post :toggle_typing
            post :transcript
            get  :toggle_status
          end
        end
        resource :contact, only: [:show, :update] do
          collection do
            post :destroy_custom_attributes
            patch :set_user
          end
        end
        resources :inbox_members, only: [:index]
        resources :labels, only: [:create, :destroy]
        namespace :integrations do
          resource :dyte, controller: 'dyte', only: [] do
            collection do
              post :add_participant_to_meeting
            end
          end
        end
      end
    end

    namespace :v2 do
      resources :accounts, only: [:create] do
        scope module: :accounts do
          resources :summary_reports, only: [] do
            collection do
              get :agent
              get :team
              get :inbox
              get :label
              get :channel
            end
          end
          resources :reports, only: [:index] do
            collection do
              get :summary
              get :bot_summary
              get :agents
              get :inboxes
              get :labels
              get :teams
              get :conversations
              get :conversations_summary
              get :conversation_traffic
              get :bot_metrics
              get :inbox_label_matrix
              get :first_response_time_distribution
              get :outgoing_messages_count
            end
          end
          resource :year_in_review, only: [:show]
          resources :live_reports, only: [] do
            collection do
              get :conversation_metrics
              get :grouped_conversation_metrics
            end
          end
        end
      end
    end
  end

  if ChatwootApp.enterprise?
    namespace :enterprise, defaults: { format: 'json' } do
      namespace :api do
        namespace :v1 do
          resources :accounts do
            member do
              post :checkout
              post :subscription
              get :limits
              post :toggle_deletion
              post :topup_checkout
            end
          end
        end
      end

      post 'webhooks/stripe', to: 'webhooks/stripe#process_payload'
      post 'webhooks/firecrawl', to: 'webhooks/firecrawl#process_payload'
    end
  end

  # ----------------------------------------------------------------------
  # Routes for platform APIs
  namespace :platform, defaults: { format: 'json' } do
    namespace :api do
      namespace :v1 do
        resources :users, only: [:create, :show, :update, :destroy] do
          member do
            get :login
            post :token
          end
        end
        resources :agent_bots, only: [:index, :create, :show, :update, :destroy] do
          delete :avatar, on: :member
        end
        resources :accounts, only: [:index, :create, :show, :update, :destroy] do
          resources :account_users, only: [:index, :create] do
            collection do
              delete :destroy
            end
          end
          resources :email_channel_migrations, only: [:create]
        end
      end
    end
  end

  # ----------------------------------------------------------------------
  # Routes for inbox APIs Exposed to contacts
  namespace :public, defaults: { format: 'json' } do
    namespace :api do
      namespace :v1 do
        resources :inboxes do
          scope module: :inboxes do
            resources :contacts, only: [:create, :show, :update] do
              resources :conversations, only: [:index, :create, :show] do
                member do
                  post :toggle_status
                  post :toggle_typing
                  post :update_last_seen
                end

                resources :messages, only: [:index, :create, :update]
              end
            end
          end
        end

        resources :csat_survey, only: [:show, :update]
      end
    end
  end

  get 'hc/:slug', to: 'public/api/v1/portals#show'
  get 'hc/:slug/sitemap.xml', to: 'public/api/v1/portals#sitemap'
  get 'hc/:slug/:locale', to: 'public/api/v1/portals#show'
  get 'hc/:slug/:locale/articles', to: 'public/api/v1/portals/articles#index'
  get 'hc/:slug/:locale/categories', to: 'public/api/v1/portals/categories#index'
  get 'hc/:slug/:locale/categories/:category_slug', to: 'public/api/v1/portals/categories#show'
  get 'hc/:slug/:locale/categories/:category_slug/articles', to: 'public/api/v1/portals/articles#index'
  get 'hc/:slug/articles/:article_slug.png', to: 'public/api/v1/portals/articles#tracking_pixel'
  get 'hc/:slug/articles/:article_slug', to: 'public/api/v1/portals/articles#show'

  # ----------------------------------------------------------------------
  # Used in mailer templates
  resource :app, only: [:index] do
    resources :accounts do
      resources :conversations, only: [:show]
    end
  end

  # ----------------------------------------------------------------------
  # Routes for channel integrations
  mount Facebook::Messenger::Server, at: 'bot'
  get 'webhooks/twitter', to: 'api/v1/webhooks#twitter_crc'
  post 'webhooks/twitter', to: 'api/v1/webhooks#twitter_events'
  post 'webhooks/line/:line_channel_id', to: 'webhooks/line#process_payload'
  post 'webhooks/telegram/:bot_token', to: 'webhooks/telegram#process_payload'
  post 'webhooks/telegram_notifications/:webhook_secret', to: 'webhooks/telegram_notifications#process_payload'
  post 'webhooks/telegram_personal/:webhook_identifier', to: 'webhooks/telegram_personal#process_payload'
  post 'webhooks/weixin/:webhook_identifier', to: 'webhooks/weixin#process_payload'
  post 'webhooks/vk/:callback_id', to: 'webhooks/vk#process_payload'
  post 'webhooks/sms/:phone_number', to: 'webhooks/sms#process_payload'
  get 'webhooks/whatsapp/:phone_number', to: 'webhooks/whatsapp#verify'
  post 'webhooks/whatsapp/:phone_number', to: 'webhooks/whatsapp#process_payload'
  post 'webhooks/whatsapp_web/:webhook_identifier', to: 'webhooks/whatsapp_web#process_payload'
  get 'webhooks/instagram', to: 'webhooks/instagram#verify'
  post 'webhooks/instagram', to: 'webhooks/instagram#events'
  post 'webhooks/tiktok', to: 'webhooks/tiktok#events'
  post 'webhooks/shopify', to: 'webhooks/shopify#events'
  post 'webhooks/macrocrm/:webhook_key/manager_changed', to: 'webhooks/macrocrm#manager_changed'

  namespace :twitter do
    resource :callback, only: [:show]
  end

  namespace :linear do
    resource :callback, only: [:show]
  end

  namespace :shopify do
    resource :callback, only: [:show]
  end

  namespace :twilio do
    resources :callback, only: [:create]
    resources :delivery_status, only: [:create]

    if ChatwootApp.enterprise?
      post 'voice/call/:phone', to: 'voice#call_twiml', as: :voice_call
      post 'voice/status/:phone', to: 'voice#status', as: :voice_status
      post 'voice/conference_status/:phone', to: 'voice#conference_status', as: :voice_conference_status
    end
  end

  post 'telephony/internal/events', to: 'telephony/bridge_events#create'
  post 'internal/voice/inbound/route', to: 'telephony/bridge_routes#create'
  post 'internal/voice/inbound/event', to: 'telephony/bridge_events#create'
  get 'internal/voice/ai/context', to: 'internal/voice/ai/context#show'
  post 'internal/voice/ai/context', to: 'internal/voice/ai/context#create'
  post 'internal/voice/ai/transcript', to: 'internal/voice/ai/transcripts#create'
  post 'internal/voice/ai/tools/:name', to: 'internal/voice/ai/tools#create'
  post 'internal/voice/ai/control', to: 'internal/voice/ai/control#create'
  post 'internal/voice/ai/event', to: 'internal/voice/ai/events#create'
  post 'internal/voice/ai/finalize', to: 'internal/voice/ai/finalizations#create'
  post 'internal/voice/recordings/ready', to: 'internal/voice/recordings#ready'

  get 'microsoft/callback', to: 'microsoft/callbacks#show'
  get 'google/callback', to: 'google/callbacks#show'
  get 'instagram/callback', to: 'instagram/callbacks#show'
  get 'tiktok/callback', to: 'tiktok/callbacks#show'
  get 'notion/callback', to: 'notion/callbacks#show'

  # Media server callbacks — authenticated by shared MEDIA_SERVER_AUTH_TOKEN,
  # not a user session. Intentionally top-level and not account-scoped.
  namespace :callbacks do
    namespace :media_server do
      post :agent_disconnected, to: '/media_server/callbacks#agent_disconnected'
      post :recording_ready, to: '/media_server/callbacks#recording_ready'
      post :session_terminated, to: '/media_server/callbacks#session_terminated'
      post :error, to: '/media_server/callbacks#error'
    end
  end

  # ----------------------------------------------------------------------
  # Routes for external service verifications
  get '.well-known/assetlinks.json' => 'android_app#assetlinks'
  get '.well-known/apple-app-site-association' => 'apple_app#site_association'
  get '.well-known/microsoft-identity-association.json' => 'microsoft#identity_association'
  get '.well-known/cf-custom-hostname-challenge/:id', to: 'custom_domains#verify'

  # ----------------------------------------------------------------------
  # Internal Monitoring Routes
  require 'sidekiq/web'
  require 'sidekiq/cron/web'

  devise_for :super_admins, path: 'super_admin', controllers: { sessions: 'super_admin/devise/sessions' }
  devise_scope :super_admin do
    get 'super_admin/logout', to: 'super_admin/devise/sessions#destroy'
    namespace :super_admin do
      root to: 'dashboard#index'

      resource :app_config, only: [:show, :create]
      resource :push_diagnostics, only: [:show, :create] do
        post :destroy_subscriptions, on: :collection
      end

      # order of resources affect the order of sidebar navigation in super admin
      resources :accounts, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
        post :seed, on: :member
        post :reset_cache, on: :member
        if ChatwootApp.enterprise?
          post :reset_captain_responses_usage, on: :member
          post :reset_captain_tokens_usage, on: :member
          post :reset_email_usage, on: :member
        end
      end
      resources :users, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
        delete :avatar, on: :member, action: :destroy_avatar
      end

      resources :access_tokens, only: [:index, :show]
      resources :installation_configs, only: [:index, :new, :create, :show, :edit, :update]
      resources :agent_bots, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
        delete :avatar, on: :member, action: :destroy_avatar
      end
      resources :platform_apps, only: [:index, :new, :create, :show, :edit, :update, :destroy]
      resources :platform_banners, only: [:index, :new, :create, :show, :edit, :update, :destroy]
      resource :instance_status, only: [:show]
      resource :monitoring, only: [:show]
      resource :captain_observability, only: [:show], controller: 'captain_observability'
      get 'logs', to: 'logs#show', as: :logs

      resource :settings, only: [:show] do
        get :refresh, on: :collection
      end

      # resources that doesn't appear in primary navigation in super admin
      resources :account_users, only: [:new, :create, :show, :destroy]
    end
    authenticated :super_admin do
      mount Sidekiq::Web => '/monitoring/sidekiq'
    end
  end

  namespace :installation do
    get 'onboarding', to: 'onboarding#index'
    post 'onboarding', to: 'onboarding#create'
  end

  # ---------------------------------------------------------------------
  # Routes for swagger docs
  get '/swagger/*path', to: 'swagger#respond'
  get '/swagger', to: 'swagger#respond'

  # ----------------------------------------------------------------------
  # Routes for testing
  resources :widget_tests, only: [:index] unless Rails.env.production?
end
