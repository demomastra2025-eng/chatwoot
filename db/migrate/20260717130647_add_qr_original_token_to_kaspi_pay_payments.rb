class AddQrOriginalTokenToKaspiPayPayments < ActiveRecord::Migration[7.1]
  def change
    add_column :kaspi_pay_payments, :qr_original_token, :string
  end
end
