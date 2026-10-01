# Family number of a contact card (M4, M5 b). Permission parity with Actions::ContactMergesController: any user of the
# account that can open the contact; contacts of other accounts are 404 (BaseController#ensure_contact).
# Promotion needs ONELINK_SHARED_PHONE_MANUAL_PROMOTION (and ONELINK_SHARED_PHONE_HISTORY_TRANSFER when chats would
# move); while a switch is off the endpoint answers 422 with SHARED_PHONE_PROMOTION_DISABLED or
# SHARED_PHONE_HISTORY_TRANSFER_DISABLED and nothing changes.
class Api::V1::Accounts::Contacts::SharedPhonesController < Api::V1::Accounts::Contacts::BaseController
  UNPROCESSABLE_CODES = (['SHARED_PHONE_NOT_ELIGIBLE'] + Contacts::SharedPhonePromotionService::DISABLED_CODES).freeze

  def show
    render json: Contacts::SharedPhonePresenter.new(contact: @contact).as_json
  end

  def promote
    result = Contacts::SharedPhonePromotionService.new(card: @contact, basis: 'administrator', actor: Current.user,
                                                       expected_fingerprint: params[:fingerprint].to_s.presence).perform
    render json: { transfer_id: result.entry&.dig('id'), promoted: result.status == :promoted, moved: result.moved }
  rescue Contacts::SharedPhonePromotionService::Error => e
    render json: { code: e.code, error: e.message }, status: UNPROCESSABLE_CODES.include?(e.code) ? :unprocessable_entity : :conflict
  end

  def dismiss_hint
    Contacts::SharedPhoneHint.dismiss!(@contact)
    head :no_content
  end
end
