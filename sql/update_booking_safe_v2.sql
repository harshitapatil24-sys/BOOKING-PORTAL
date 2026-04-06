-- ============================================
-- SAFE BOOKING SLOT UPDATE FUNCTION v2
-- ============================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- ============================================

-- Drop old function first
DROP FUNCTION IF EXISTS update_booking_safe_v2(UUID, DATE, UUID[], TEXT, TEXT);

CREATE OR REPLACE FUNCTION update_booking_safe_v2(
  p_booking_id UUID,
  p_new_date DATE,
  p_new_slot_ids UUID[],
  p_new_status TEXT,
  p_new_reason TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old_slot_count INT;
  v_new_slot_count INT;
  v_conflict_count INT;
  v_slot_id UUID;
BEGIN

  -- Verify booking exists
  IF NOT EXISTS (SELECT 1 FROM booking_requests WHERE id = p_booking_id) THEN
    RETURN json_build_object('success', false, 'error', 'Booking not found');
  END IF;

  -- Normalize array
  p_new_slot_ids := COALESCE(p_new_slot_ids, ARRAY[]::UUID[]);

  -- ========================================
  -- HANDLE ACCEPTED STATUS
  -- ========================================
  IF p_new_status = 'accepted' THEN

    -- Check for conflicts with OTHER accepted bookings on same date
    IF array_length(p_new_slot_ids, 1) > 0 THEN
      SELECT COUNT(*) INTO v_conflict_count
      FROM booking_slots bs
      JOIN booking_requests br ON br.id = bs.booking_id
      WHERE br.booking_date = p_new_date
        AND br.status = 'accepted'
        AND br.id != p_booking_id
        AND bs.slot_id = ANY(p_new_slot_ids);

      IF v_conflict_count > 0 THEN
        RETURN json_build_object(
          'success', false,
          'error', 'Slot conflict: ' || v_conflict_count || ' slot(s) already booked by another event'
        );
      END IF;
    END IF;

    -- Count old slots
    SELECT COUNT(*) INTO v_old_slot_count
    FROM booking_slots
    WHERE booking_id = p_booking_id;

    -- *** CRITICAL: DELETE ALL OLD SLOTS FIRST ***
    DELETE FROM booking_slots
    WHERE booking_id = p_booking_id;

    -- *** INSERT NEW SLOTS ONE BY ONE ***
    IF array_length(p_new_slot_ids, 1) > 0 THEN
      FOREACH v_slot_id IN ARRAY p_new_slot_ids
      LOOP
        INSERT INTO booking_slots (booking_id, slot_id)
        VALUES (p_booking_id, v_slot_id)
        ON CONFLICT (booking_id, slot_id) DO NOTHING;
      END LOOP;
    END IF;

    -- Count new slots
    SELECT COUNT(*) INTO v_new_slot_count
    FROM booking_slots
    WHERE booking_id = p_booking_id;

    -- Update booking record
    UPDATE booking_requests
    SET
      booking_date = p_new_date,
      status = 'accepted',
      rejection_reason = NULL
    WHERE id = p_booking_id;

    RETURN json_build_object(
      'success', true,
      'slots_removed', v_old_slot_count,
      'slots_added', v_new_slot_count,
      'total_slots', v_new_slot_count
    );

  -- ========================================
  -- HANDLE REJECTED STATUS - DO NOT TOUCH SLOTS
  -- ========================================
  ELSIF p_new_status = 'rejected' THEN

    UPDATE booking_requests
    SET
      booking_date = p_new_date,
      status = 'rejected',
      rejection_reason = p_new_reason
    WHERE id = p_booking_id;

    SELECT COUNT(*) INTO v_new_slot_count
    FROM booking_slots
    WHERE booking_id = p_booking_id;

    RETURN json_build_object(
      'success', true,
      'slots_removed', 0,
      'slots_added', 0,
      'total_slots', v_new_slot_count,
      'message', 'Booking rejected, slots unchanged'
    );

  -- ========================================
  -- HANDLE PENDING STATUS
  -- ========================================
  ELSE

    -- Count old slots
    SELECT COUNT(*) INTO v_old_slot_count
    FROM booking_slots
    WHERE booking_id = p_booking_id;

    -- Delete all old slots
    DELETE FROM booking_slots
    WHERE booking_id = p_booking_id;

    -- Insert new slots
    IF array_length(p_new_slot_ids, 1) > 0 THEN
      FOREACH v_slot_id IN ARRAY p_new_slot_ids
      LOOP
        INSERT INTO booking_slots (booking_id, slot_id)
        VALUES (p_booking_id, v_slot_id)
        ON CONFLICT (booking_id, slot_id) DO NOTHING;
      END LOOP;
    END IF;

    -- Count new slots
    SELECT COUNT(*) INTO v_new_slot_count
    FROM booking_slots
    WHERE booking_id = p_booking_id;

    UPDATE booking_requests
    SET
      booking_date = p_new_date,
      status = p_new_status,
      rejection_reason = NULL
    WHERE id = p_booking_id;

    RETURN json_build_object(
      'success', true,
      'slots_removed', v_old_slot_count,
      'slots_added', v_new_slot_count,
      'total_slots', v_new_slot_count
    );

  END IF;

END;
$$;

-- ============================================
-- ENSURE UNIQUE CONSTRAINT EXISTS
-- ============================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'unique_booking_slot'
  ) THEN
    ALTER TABLE booking_slots
    ADD CONSTRAINT unique_booking_slot UNIQUE (booking_id, slot_id);
  END IF;
EXCEPTION WHEN others THEN
  NULL;
END $$;

-- ============================================
-- GRANT PERMISSIONS
-- ============================================
GRANT EXECUTE ON FUNCTION update_booking_safe_v2 TO authenticated;
GRANT EXECUTE ON FUNCTION update_booking_safe_v2 TO anon;
