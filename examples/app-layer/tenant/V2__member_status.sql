-- Example of a later change in the application layer: a new column.
-- Tenants that already have V1 receive this on the next scripts/upgrade.sh.
ALTER TABLE ${tenant}.members
  ADD COLUMN status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed'));
