-- Example application layer, database-wide objects.
--
-- 1. Register the account and entry types this application uses. Every
--    tenant shares them. Registration is idempotent, so the same calls can
--    sit in a migration and in a test seed.
SELECT ledger_shared.register_account_type('topup_funding',    NULL,       true,  'Money received from card top-ups');
SELECT ledger_shared.register_account_type('member_wallet',    'member',   false, 'A member''s stored balance');
SELECT ledger_shared.register_account_type('merchant_payable', 'merchant', false, 'What the app owes a merchant');
SELECT ledger_shared.register_entry_type('topup',    'A member adds money to their wallet');
SELECT ledger_shared.register_entry_type('purchase', 'A member pays a merchant from their wallet');

-- 2. The application's own database-wide tables go in the application's own
--    schema, not in the ledger's "shared" schema.
CREATE SCHEMA example_app;
CREATE TABLE example_app.merchants (
  merchant_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name    text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
