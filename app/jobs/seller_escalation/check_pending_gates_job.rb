module SellerEscalation
  class CheckPendingGatesJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      sellers = JSON.parse(ENV.fetch('VASCAINO_SELLERS_JSON'))

      pending_phones.each do |phone|
        SellerEscalationService.new(phone, sellers: sellers).escalate_if_due!
      end
    end

    private

    # Pending gates are tracked as Redis keys "price_gate:<phone>"; scan for them
    # rather than keeping a separate index, since the gate itself is the source
    # of truth for "is this phone waiting on a seller". Uses the same $alfred
    # connection pool Redis::Alfred wraps internally (no public raw accessor).
    def pending_phones
      $alfred.with { |conn| conn.scan_each(match: 'price_gate:*').to_a }.map { |key| key.sub('price_gate:', '') }
    end
  end
end
