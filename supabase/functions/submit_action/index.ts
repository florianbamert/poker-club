// Phase 0 — submit_action
// Nimmt eine Spieler-Absicht entgegen (fold/check/call/bet/raise), validiert
// sie serverseitig (siehe applyAction in _shared/poker.ts) und schreibt den
// neuen Zustand. Bei Showdown wird der Gewinner direkt hier ermittelt und
// der Pot ausgezahlt.
//
// Bekannte Vereinfachung für Phase 0 (siehe Architektur-Spezifikation,
// "Offene Risiken"): Das Lesen+Schreiben läuft NICHT in einer einzigen
// Postgres-Transaktion, sondern optimistisch — der UPDATE greift nur, wenn
// `updated_at` seit dem Lesen nicht verändert wurde. Weil immer nur der
// Sitz am Zug schreiben darf (current_seat-Check), ist das Risiko einer
// echten Kollision bei nur 2 Spielern sehr gering, aber vor Phase 1 sollte
// das durch eine atomare SQL-Funktion ersetzt werden.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { applyAction, resolveShowdown, type ActionType, type HandState } from '../_shared/poker.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  try {
    const { table_id, action, amount } = await req.json() as { table_id: string; action: ActionType; amount?: number };
    if (!table_id || !action) return json({ error: 'table_id oder action fehlt' }, 400);

    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: seatsRaw } = await admin.from('online_seats').select('seat_no, user_id, stack').eq('table_id', table_id).order('seat_no');
    if (!seatsRaw || seatsRaw.length !== 2) return json({ error: 'table_not_ready' }, 400);
    const mySeatRow = seatsRaw.find(s => s.user_id === user.id);
    if (!mySeatRow) return json({ error: 'not_seated' }, 403);
    const actingSeat = mySeatRow.seat_no as 0 | 1;
    const seats = { 0: seatsRaw[0], 1: seatsRaw[1] } as Record<number, { seat_no: 0 | 1; stack: number }>;

    const { data: stateRow } = await admin.from('online_hand_state').select('*').eq('table_id', table_id).single();
    if (!stateRow) return json({ error: 'no_hand' }, 400);

    const state: HandState = {
      phase: stateRow.phase, dealer_seat: stateRow.dealer_seat, board: stateRow.board,
      deck: stateRow.deck, pot: Number(stateRow.pot), current_seat: stateRow.current_seat,
      bets: stateRow.bets, acted: stateRow.acted, folded: stateRow.folded,
      last_raise_size: Number(stateRow.last_raise_size),
    };

    const result = applyAction(state, seats, actingSeat, action, amount);
    if (result.error) return json({ error: result.error }, 400);

    const newState = result.state!;
    const newStacks = result.stacks!;

    // Optimistischer Schreibschutz: nur anwenden, wenn seit dem Lesen
    // niemand anders geschrieben hat.
    const { data: written, error: updateErr } = await admin
      .from('online_hand_state')
      .update({
        phase: newState.phase, board: newState.board, deck: newState.deck, pot: newState.pot,
        current_seat: newState.current_seat, bets: newState.bets, acted: newState.acted,
        folded: newState.folded, last_raise_size: newState.last_raise_size, updated_at: new Date().toISOString(),
      })
      .eq('table_id', table_id)
      .eq('updated_at', stateRow.updated_at)
      .select()
      .maybeSingle();
    if (updateErr) return json({ error: updateErr.message }, 500);
    if (!written) return json({ error: 'state_changed_meanwhile', retry: true }, 409);

    for (const seatNo of [0, 1] as const) {
      if (newStacks[seatNo] !== seats[seatNo].stack) {
        await admin.from('online_seats').update({ stack: newStacks[seatNo] }).eq('table_id', table_id).eq('seat_no', seatNo);
      }
    }

    let winnerSeat: 0 | 1 | null = null;
    let handFinished = false;

    if (result.handOver) {
      // Durch Fold entschieden: der verbleibende Sitz bekommt den ganzen Pot.
      winnerSeat = result.winnerSeat!;
      handFinished = true;
    } else if (newState.phase === 'showdown') {
      const sd = resolveShowdown(stateRow.hole_cards, newState.board);
      winnerSeat = sd.winnerSeat;
      handFinished = true;
    }

    if (handFinished) {
      const potAmount = newState.pot;
      if (winnerSeat === null) {
        // Split Pot
        await admin.from('online_seats').update({ stack: newStacks[0] + potAmount / 2 }).eq('table_id', table_id).eq('seat_no', 0);
        await admin.from('online_seats').update({ stack: newStacks[1] + potAmount / 2 }).eq('table_id', table_id).eq('seat_no', 1);
      } else {
        await admin.from('online_seats').update({ stack: newStacks[winnerSeat] + potAmount }).eq('table_id', table_id).eq('seat_no', winnerSeat);
      }
      await admin.from('online_hand_history').insert({
        table_id, hand_no: stateRow.hand_no,
        summary: { board: newState.board, hole_cards: stateRow.hole_cards, pot: potAmount, winner_seat: winnerSeat, phase_ended: newState.phase },
      });
      await admin.from('online_hand_state').update({ phase: 'done' }).eq('table_id', table_id);
    }

    const publicChannel = admin.channel(`table:${table_id}:public`);
    await publicChannel.send({
      type: 'broadcast', event: 'state',
      payload: {
        phase: handFinished ? 'done' : newState.phase, board: newState.board, pot: handFinished ? 0 : newState.pot,
        current_seat: newState.current_seat, bets: newState.bets, last_action: { seat: actingSeat, action, amount },
        hand_over: handFinished, winner_seat: winnerSeat,
        // Beim Showdown werden die Karten regelkonform öffentlich — das ist
        // kein Leck, sondern Poker-Standard (alle zeigen am River ihre Hand).
        revealed_hole_cards: newState.phase === 'showdown' || handFinished ? stateRow.hole_cards : undefined,
      },
    });

    return json({ ok: true, phase: handFinished ? 'done' : newState.phase, hand_over: handFinished, winner_seat: winnerSeat });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
