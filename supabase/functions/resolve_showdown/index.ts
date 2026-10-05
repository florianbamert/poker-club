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
//    submit_action (resolveMultiwayShowdown + Pot-Verteilung + History-
//    Eintrag), nur ohne erneute Aktion entgegenzunehmen.
//
// Mehrweg (2–10 Sitze): state.seat_order ersetzt die frühere feste
// [0,1]-Annahme; Side-Pots und die "niemand muss zeigen"-Regel laufen
// identisch zu submit_action über resolveMultiwayShowdown().

import { createClient } from 'npm:@supabase/supabase-js@2';
import { resolveMultiwayShowdown } from '../_shared/poker.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

// CORS: der Browser (GitHub Pages) ruft die Funktion direkt auf und schickt vorher eine OPTIONS-Anfrage
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
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

    const seatOrder: number[] = stateRow.seat_order || [];
    const sd = resolveMultiwayShowdown(
      stateRow.hole_cards, stateRow.board, seatOrder, stateRow.folded, stateRow.contributions || {}, stateRow.last_aggressor ?? null,
    );
    const payouts = sd.payouts;

    const { data: seatsRaw } = await admin.from('online_seats').select('seat_no, stack').eq('table_id', table_id).in('seat_no', seatOrder);
    if (!seatsRaw || seatsRaw.length !== seatOrder.length) return json({ error: 'table_not_ready' }, 400);
    const stacks: Record<number, number> = {};
    for (const s of seatsRaw) stacks[s.seat_no] = Number(s.stack);

    for (const seatNo of Object.keys(payouts)) {
      const amt = payouts[Number(seatNo)];
      if (amt > 0.0001) {
        await admin.from('online_seats').update({ stack: stacks[Number(seatNo)] + amt }).eq('table_id', table_id).eq('seat_no', Number(seatNo));
      }
    }

    const revealedHoleCards: Record<string, string[]> = {};
    for (const s of sd.revealSeats) revealedHoleCards[s] = stateRow.hole_cards[String(s)];

    const summary = { board: stateRow.board, revealed_hole_cards: revealedHoleCards, payouts, phase_ended: 'showdown' };
    await admin.from('online_hand_history').insert({ table_id, hand_no: stateRow.hand_no, summary });
    await admin.from('online_hand_state').update({ phase: 'done', pot: 0, revealed_hole_cards: revealedHoleCards }).eq('table_id', table_id);

    const publicChannel = admin.channel(`table:${table_id}:public`);
    await publicChannel.send({
      type: 'broadcast', event: 'state',
      payload: {
        phase: 'done', board: stateRow.board, pot: 0, current_seat: stateRow.current_seat,
        hand_over: true, payouts, revealed_hole_cards: revealedHoleCards,
      },
    });

    return json({ ok: true, already_resolved: false, payouts, summary });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
