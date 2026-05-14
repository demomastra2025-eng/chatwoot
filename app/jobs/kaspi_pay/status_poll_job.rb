class KaspiPay::StatusPollJob < ApplicationJob
  queue_as :default

  def perform(payment_id)
    payment = KaspiPay::Payment.find(payment_id)
    KaspiPay::StatusSyncService.new(payment: payment).sync!

    return if payment.reload.final_status?

    self.class.set(wait: next_poll_delay(payment)).perform_later(payment.id)
  end

  private

  def next_poll_delay(payment)
    age = Time.current - payment.created_at
    return 5.seconds if age < 2.minutes
    return 15.seconds if age < 10.minutes

    1.minute
  end
end
