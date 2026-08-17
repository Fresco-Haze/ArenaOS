module Domain.Role
  ( Role(..)
  ) where

-- Extensible by design (mirrors RegistrationStatus/INV-2). Persisted
-- membership is reserved for roles requiring independent authorization
-- semantics no existing domain relationship can express (ROLE-MODEL-002/C).
-- Administrator is currently the only role meeting that bar
-- (ROLE-MODEL-004/B1).
--
-- Additional constructors shall be introduced only when new evidence
-- establishes an independently authorized role requiring persisted
-- membership. Section 3 roles that remain representable through existing
-- domain relationships (Player, Team Captain, Organizer) are not added
-- merely to mirror the Section 3 taxonomy. (ROLE-MODEL-005)
data Role
  = Administrator
  deriving (Show, Eq)