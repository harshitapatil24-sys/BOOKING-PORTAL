-- ============================================================
-- PRODUCTION-LEVEL SAFE BOOKING SLOT UPDATE SYSTEM
-- ============================================================
-- Version: 3.0
-- Database: PostgreSQL / Supabase
-- Purpose: Safe slot updates without affecting other bookings
-- ============================================================

-- ============================================================
-- STEP 1: ENSURE PROPER TABLE STRUCTURE
-- ============================================================

-- Add unique constraint to prevent duplicate booking-slot pairs
ALTER TABLE booking_slots
DROP CONSTRAINT IF EXISTS unique_booking_slot;

ALTER TABLE booking_slots
ADD CONSTRAINT unique_booking_slot UNIQUE (booking_id, slot_id);

-- ============================================================
-- STEP 2: CREATE HELPER FUNCTION - Check Slot Availability
-- ============================================================

CREATE OR REPLACE FUNCTION is_slot_available(
  p_slot_id UUID,
  p_date DATE,
  p_exclude_booking_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN NOT EXISTS (
    SELECT 1
    FROM booking_slots bs
    JOIN booking_requests br ON br.id = bs.booking_id
    WHERE bs.slot_id = p_slot_id
      AND br.booking_date = p_date
      AND br.status = 'accepted'
      AND (p_exclude_booking_id IS NULL OR br.id != p_exclude_booking_id)
  );
END;
$$;

-- ============================================================
-- STEP 3: MAIN SAFE UPDATE FUNCTION (PRODUCTION VERSION)
-- ============================================================

DROP FUNCTION IF EXISTS update_booking_safe_v3(UUID, DATE, UUID[], TEXT, TEXT);

CREATE OR REPLACE FUNCTION update_booking_safe_v3(
  p_booking_id UUID,        -- The booking to update
  p_new_date DATE,          -- New booking date
  p_new_slot_ids UUID[],    -- Array of selected slot IDs
  p_new_status TEXT,        -- New status (pending/accepted/rejected)
  p_new_reason TEXT         -- Rejection reason (if rejecting)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER  -- Run with elevated privileges
AS $$
DECLARE
  v_old_date DATE;
  v_old_status TEXT;
  v_old_slot_ids UUID[];
  v_slots_to_add UUID[];
  v_slots_to_remove UUID[];
  v_available_to_add UUID[];
  v_unavailable_slots UUID[];
  v_slots_kept UUID[];
  v_added_count INT := 0;
  v_removed_count INT := 0;
  v_conflict_details JSONB;
BEGIN
  -- ========================================
  -- LOCK THE BOOKING ROW FOR UPDATE
  -- Prevents concurrent modifications
  -- ========================================
  SELECT booking_date, status
  INTO v_old_date, v_old_status
  FROM booking_requests
  WHERE id = p_booking_id
  FOR UPDATE;  -- Row-level lock

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Booking not found',
      'code', 'BOOKING_NOT_FOUND'
    );
  END IF;

  -- ========================================
  -- GET CURRENT SLOTS FOR THIS BOOKING
  -- ========================================
  SELECT COALESCE(ARRAY_AGG(slot_id), ARRAY[]::UUID[])
  INTO v_old_slot_ids
  FROM booking_slots
  WHERE booking_id = p_booking_id;

  -- Normalize input array
  p_new_slot_ids := COALESCE(p_new_slot_ids, ARRAY[]::UUID[]);

  -- ========================================
  -- CALCULATE SLOT DIFFERENCES
  -- ========================================

  -- Slots to ADD = in new BUT not in old
  SELECT ARRAY(
    SELECT unnest(p_new_slot_ids)
    EXCEPT
    SELECT unnest(v_old_slot_ids)
  ) INTO v_slots_to_add;

  -- Slots to REMOVE = in old BUT not in new
  SELECT ARRAY(
    SELECT unnest(v_old_slot_ids)
    EXCEPT
    SELECT unnest(p_new_slot_ids)
  ) INTO v_slots_to_remove;

  -- Slots being KEPT = in both old and new
  SELECT ARRAY(
    SELECT unnest(v_old_slot_ids)
    INTERSECT
    SELECT unnest(p_new_slot_ids)
  ) INTO v_slots_kept;

  -- ========================================
  -- CHECK AVAILABILITY OF NEW SLOTS
  -- (Only if status will be 'accepted')
  -- ========================================
  IF p_new_status = 'accepted' AND array_length(v_slots_to_add, 1) > 0 THEN

    -- Find which new slots are already booked by OTHERS
    SELECT ARRAY_AGG(s.slot_id)
    INTO v_unavailable_slots
    FROM (
      SELECT unnest(v_slots_to_add) AS slot_id
    ) s
    WHERE NOT is_slot_available(s.slot_id, p_new_date, p_booking_id);

    -- If any slots are unavailable, return error with details
    IF v_unavailable_slots IS NOT NULL AND array_length(v_unavailable_slots, 1) > 0 THEN

      -- Get conflict details
      SELECT jsonb_agg(jsonb_build_object(
        'slot_id', bs.slot_id,
        'slot_info', sl.slot_label || ' (' || sl.start_time || ' - ' || sl.end_time || ')',
        'booked_by_booking', br.id,
        'booked_by_event', br.event_name
      ))
      INTO v_conflict_details
      FROM booking_slots bs
      JOIN booking_requests br ON br.id = bs.booking_id
      JOIN slots sl ON sl.id = bs.slot_id
      WHERE bs.slot_id = ANY(v_unavailable_slots)
        AND br.booking_date = p_new_date
        AND br.status = 'accepted'
        AND br.id != p_booking_id;

      RETURN jsonb_build_object(
        'success', false,
        'error', 'Some slots are already booked by others',
        'code', 'SLOT_CONFLICT',
        'unavailable_slots', v_unavailable_slots,
        'conflict_details', v_conflict_details
      );
    END IF;

    -- All new slots are available
    v_available_to_add := v_slots_to_add;
  ELSE
    -- Not accepting, so we can add all slots (they won't cause conflicts)
    v_available_to_add := v_slots_to_add;
  END IF;

  -- ========================================
  -- UPDATE THE BOOKING RECORD
  -- ========================================
  UPDATE booking_requests
  SET
    booking_date = p_new_date,
    status = p_new_status,
    rejection_reason = CASE
      WHEN p_new_status = 'rejected' THEN p_new_reason
      WHEN p_new_status = 'accepted' THEN NULL
      ELSE rejection_reason
    END,
    updated_at = NOW()
  WHERE id = p_booking_id;

  -- ========================================
  -- REMOVE DESELECTED SLOTS
  -- Only remove if they belong to THIS booking
  -- ========================================
  IF array_length(v_slots_to_remove, 1) > 0 THEN
    DELETE FROM booking_slots
    WHERE booking_id = p_booking_id
      AND slot_id = ANY(v_slots_to_remove);

    GET DIAGNOSTICS v_removed_count = ROW_COUNT;
  END IF;

  -- ========================================
  -- ADD NEW SLOTS
  -- Using ON CONFLICT to handle race conditions
  -- ========================================
  IF array_length(v_available_to_add, 1) > 0 THEN
    INSERT INTO booking_slots (booking_id, slot_id)
    SELECT p_booking_id, unnest(v_available_to_add)
    ON CONFLICT (booking_id, slot_id) DO NOTHING;

    GET DIAGNOSTICS v_added_count = ROW_COUNT;
  END IF;

  -- ========================================
  -- RETURN SUCCESS WITH DETAILS
  -- ========================================
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Booking updated successfully',
    'details', jsonb_build_object(
      'slots_added', v_added_count,
      'slots_removed', v_removed_count,
      'slots_kept', COALESCE(array_length(v_slots_kept, 1), 0),
      'total_slots', (
        SELECT COUNT(*) FROM booking_slots WHERE booking_id = p_booking_id
      ),
      'new_status', p_new_status,
      'new_date', p_new_date
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'code', SQLSTATE
    );
END;
$$;

-- ============================================================
-- STEP 4: SIMPLIFIED VERSION (Compatible with existing code)
-- ============================================================

DROP FUNCTION IF EXISTS update_booking_safe(UUID, DATE, UUID[], TEXT, TEXT);

CREATE OR REPLACE FUNCTION update_booking_safe(
  p_booking_id UUID,
  p_new_date DATE,
  p_new_slot_ids UUID[],
  p_new_status TEXT,
  p_new_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Call the v3 function
  v_result := update_booking_safe_v3(
    p_booking_id, p_new_date, p_new_slot_ids, p_new_status, p_new_reason
  );

  -- If not successful, raise exception
  IF NOT (v_result->>'success')::BOOLEAN THEN
    RAISE EXCEPTION '%', v_result->>'error';
  END IF;
END;
$$;

-- ============================================================
-- STEP 5: TRIGGER TO PREVENT DOUBLE BOOKING ON INSERT
-- ============================================================

CREATE OR REPLACE FUNCTION prevent_double_booking()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_booking_date DATE;
  v_booking_status TEXT;
BEGIN
  -- Get booking info
  SELECT booking_date, status
  INTO v_booking_date, v_booking_status
  FROM booking_requests
  WHERE id = NEW.booking_id;

  -- Only check for accepted bookings
  IF v_booking_status = 'accepted' THEN
    IF EXISTS (
      SELECT 1
      FROM booking_slots bs
      JOIN booking_requests br ON br.id = bs.booking_id
      WHERE bs.slot_id = NEW.slot_id
        AND br.booking_date = v_booking_date
        AND br.status = 'accepted'
        AND br.id != NEW.booking_id
    ) THEN
      RAISE EXCEPTION 'Slot % is already booked for date %',
        NEW.slot_id, v_booking_date;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_double_booking ON booking_slots;

CREATE TRIGGER trg_prevent_double_booking
BEFORE INSERT ON booking_slots
FOR EACH ROW
EXECUTE FUNCTION prevent_double_booking();

-- ============================================================
-- STEP 6: TRIGGER WHEN STATUS CHANGES TO ACCEPTED
-- ============================================================

CREATE OR REPLACE FUNCTION check_slots_on_accept()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_conflicting_slot UUID;
  v_slot_info TEXT;
BEGIN
  -- Only check when status changes to 'accepted'
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status != 'accepted') THEN

    -- Check for any conflicting slots
    SELECT bs.slot_id, sl.slot_label || ' (' || sl.start_time || '-' || sl.end_time || ')'
    INTO v_conflicting_slot, v_slot_info
    FROM booking_slots bs
    JOIN slots sl ON sl.id = bs.slot_id
    WHERE bs.booking_id = NEW.id
      AND EXISTS (
        SELECT 1
        FROM booking_slots bs2
        JOIN booking_requests br2 ON br2.id = bs2.booking_id
        WHERE bs2.slot_id = bs.slot_id
          AND br2.booking_date = NEW.booking_date
          AND br2.status = 'accepted'
          AND br2.id != NEW.id
      )
    LIMIT 1;

    IF v_conflicting_slot IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot accept: Slot "%" is already booked for this date', v_slot_info;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_slots_on_accept ON booking_requests;

CREATE TRIGGER trg_check_slots_on_accept
BEFORE UPDATE ON booking_requests
FOR EACH ROW
EXECUTE FUNCTION check_slots_on_accept();

-- ============================================================
-- STEP 7: GRANT PERMISSIONS
-- ============================================================

GRANT EXECUTE ON FUNCTION update_booking_safe TO authenticated;
GRANT EXECUTE ON FUNCTION update_booking_safe_v3 TO authenticated;
GRANT EXECUTE ON FUNCTION is_slot_available TO authenticated;

-- ============================================================
-- STEP 8: VIEW FOR CHECKING SLOT AVAILABILITY
-- ============================================================

CREATE OR REPLACE VIEW slot_availability AS
SELECT
  s.id AS slot_id,
  s.slot_label,
  s.start_time,
  s.end_time,
  br.booking_date,
  CASE
    WHEN br.status = 'accepted' THEN 'booked'
    WHEN br.status = 'pending' THEN 'pending'
    ELSE 'available'
  END AS availability_status,
  br.id AS booking_id,
  br.event_name
FROM slots s
LEFT JOIN booking_slots bs ON bs.slot_id = s.id
LEFT JOIN booking_requests br ON br.id = bs.booking_id;

-- ============================================================
-- USAGE EXAMPLES
-- ============================================================

/*
-- Example 1: Update booking with new slots (returns JSONB with details)
SELECT update_booking_safe_v3(
  'booking-uuid-here',
  '2024-04-15',
  ARRAY['slot-uuid-1', 'slot-uuid-2']::UUID[],
  'accepted',
  NULL
);

-- Example 2: Simple update (throws exception on error)
SELECT update_booking_safe(
  'booking-uuid-here',
  '2024-04-15',
  ARRAY['slot-uuid-1', 'slot-uuid-2']::UUID[],
  'rejected',
  'Venue not available for this event type'
);

-- Example 3: Check if specific slot is available
SELECT is_slot_available(
  'slot-uuid-here',
  '2024-04-15',
  NULL -- or booking-id to exclude
);

-- Example 4: View slot availability for a date
SELECT * FROM slot_availability WHERE booking_date = '2024-04-15';
*/

-- ============================================================
-- LOGIC EXPLANATION
-- ============================================================

/*
STEP-BY-STEP LOGIC:

1. LOCK BOOKING ROW
   - Prevents concurrent modifications
   - Uses FOR UPDATE to acquire row lock

2. GET CURRENT STATE
   - Fetch existing slots for this booking
   - Store in v_old_slot_ids array

3. CALCULATE DIFFERENCES
   - slots_to_add = new_slots EXCEPT old_slots
   - slots_to_remove = old_slots EXCEPT new_slots
   - slots_kept = intersection of both

4. CHECK AVAILABILITY (only for 'accepted' status)
   - For each slot_to_add, check if already booked
   - Return detailed error if conflicts found

5. UPDATE BOOKING RECORD
   - Update date, status, rejection_reason

6. REMOVE DESELECTED SLOTS
   - Only remove slots belonging to THIS booking
   - Does not affect other bookings

7. ADD NEW SLOTS
   - Uses ON CONFLICT DO NOTHING for safety
   - Handles race conditions gracefully

8. RETURN RESULT
   - Success with details (added, removed, kept counts)
   - Or error with conflict details

EDGE CASES HANDLED:

1. CONCURRENT BOOKING
   - Row-level locking prevents race conditions
   - ON CONFLICT handles insert races

2. NULL ARRAYS
   - COALESCE converts NULL to empty array
   - array_length checks prevent errors

3. DATE CHANGE
   - Conflict check uses NEW date, not old

4. STATUS CHANGE TO ACCEPTED
   - Trigger validates all slots are available

5. PARTIAL FAILURE
   - Transaction rollback on any error
   - No partial updates

6. DUPLICATE SLOTS
   - Unique constraint prevents duplicates
   - ON CONFLICT DO NOTHING handles gracefully
*/
