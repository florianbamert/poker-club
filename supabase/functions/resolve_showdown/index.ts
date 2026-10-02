// Phase 0 — resolve_showdown
//
// submit_action löst einen Showdown bereits inline auf (siehe dortiger
// Kommentar), direkt nachdem die letzte Aktion die Setzrunde abgeschlossen
// hat. resolve_showdown ist der explizite, idempotente Zwilling dazu:
//
//  - Normalfall: wird gar nicht gebraucht, weil submit_action den Showdown
//    schon ausgewertet hat.
//  - Absicherung: falls der Broadcast nach einem erfolgreichen
//    submit_action-Aufruf nie ankam (Verbindungsabbruch beim Client) oder
//    ein Client einfach den aktuellen Stand neu abfragen will, kann er
//    resolve_showdown aufrufen — es wiederholt NICHT die Pot-Auszahlung,
//    wenn die Hand bereits phase='done' hat, sondern liefert nur den
//    bereits erfassten Ausgang aus der letzten online_hand_history-Zeile.
//  - Ist die Hand wider Erwarten noch in phase='showdown' hängen
//    geblieben (z. B. weil submit_action zwischen UPDATE und Broadcast
//    abgebrochen ist), holt diese Funktion das nach: gleiche Logik wie in
//    submit_action (resolveShowdown + Pot-Verteilung + History-Eintrag),
//    nur ohne erneute Aktion entgegenzunehmen.
//
// Für Phase 0 bewusst als separater, manuell aufrufbarer Endpunkt gehalten
// (wie im Architektur-Spezifikation-Interface vorgesehen), auch wenn der
// Hauptpfad meist über submit_action läuft.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { resolveShowdown } from '../_shared/poker.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  try {
    const { table_id } = await req.json() as { table_id: string };
    if (!table_id) return json({ error: 'table_id fehlt' }, 400);

    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: mySeat } = await admin.from('online_seats').select('seat_no').eq('table_id', table_id).eq('user_id', user.id).maybeSingle();
    if (!mySeat) return json({ error: 'not_seated' }, 403);

    const { data: stateRow } = await admin.from('online_hand_state').select('*').eq('table_id', table_id).single();
    if (!stateRow) return json({ error: 'no_hand' }, 400);

    // Hand bereits fertig abgerechnet: letzten History-Eintrag zurückgeben,
    // nichts erneut auszahlen.
    if (stateRow.phase === 'done') {
      const { data: lastHistory } = await admin
        .from('online_hand_history')
        .select('*')
        .eq('table_id', table_id)
        .eq('hand_no', stateRow.hand_no)
        .maybeSingle();
      return json({ ok: true, already_resolved: true, summary: lastHistory?.summary ?? null });
    }

    if (stateRow.phase !== 'showdown') {
      return json({ error: 'not_at_showdown', phase: stateRow.phase }, 400);
    }

    const sd = resolveShowdown(stateRow.hole_cards, stateRow.board);
    const winnerSeat = sd.winnerSeat;
    const potAmount = Number(stateRow.pot);

    const { data: seatsRaw } = await admin.from('online_seats').select('seat_no, stack').eq('table_id', table_id).order('seat_no');
    if (!seatsRaw || seatsRaw.length !== 2) return json({ error: 'table_not_ready' }, 400);
    const stacks: Record<number, number> = { 0: Number(seatsRaw[0].stack), 1: Number(seatsRaw[1].stack) };

    if (winnerSeat === null) {
      await admin.from('online_seats').update({ stack: stacks[0] + potAmount / 2 }).eq('table_id', table_id).eq('seat_no', 0);
      await admin.from('online_seats').update({ stack: stacks[1] + potAmount / 2 }).eq('table_id', table_id).eq('seat_no', 1);
    } else {
      await admin.from('online_seats').update({ stack: stacks[winnerSeat] + potAmount }).eq('table_id', table_id).eq('seat_no', winnerSeat);
    }

    const summary = { board: stateRow.board, hole_cards: stateRow.hole_cards, pot: potAmount, winner_seat: winnerSeat, phase_ended: 'showdown' };
    await admin.from('online_hand_history').insert({ table_id, hand_no: stateRow.hand_no, summary });
    await admin.from('online_hand_state').update({ phase: 'done', pot: 0 }).eq('table_id', table_id);

    const publicChannel = admin.channel(`table:${table_id}:public`);
    await publicChannel.send({
      type: 'broadcast', event: 'state',
      payload: {
        phase: 'done', board: stateRow.board, pot: 0, current_seat: stateRow.current_seat,
        hand_over: true, winner_seat: winnerSeat, revealed_hole_cards: stateRow.hole_cards,
      },
    });

    return json({ ok: true, already_resolved: false, winner_seat: winnerSeat, summary });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
