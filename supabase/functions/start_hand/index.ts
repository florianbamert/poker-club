// Phase 0 — start_hand
// Ruft die atomare SQL-Funktion deal_hand() auf (Shuffle + Deal + Blinds),
// liest danach den neuen, öffentlichen Zustand und verteilt ihn:
//  - Board/Pot/Zug an den öffentlichen Broadcast-Kanal (alle Sitze)
//  - jede Hole-Card-Zuteilung NUR an den privaten Kanal des jeweiligen Sitzes
// Siehe Architektur-Spezifikation, Abschnitt "Realtime-Sync-Modell".
//
// Seit dem Mehrweg-Dealer (chipmate_online_poker_phase0_multiway.sql) gibt
// es keine feste [0,1]-Sitzliste mehr — die tatsächlich an dieser Hand
// beteiligten Sitze stehen in state.seat_order (von deal_hand() gesetzt).

import { createClient } from 'npm:@supabase/supabase-js@2';

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
    const { table_id } = await req.json();
    if (!table_id) return json({ error: 'table_id fehlt' }, 400);

    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // Nur ein Sitz an diesem Tisch darf überhaupt eine neue Hand anstossen.
    const { data: mySeat } = await admin.from('online_seats').select('seat_no').eq('table_id', table_id).eq('user_id', user.id).maybeSingle();
    if (!mySeat) return json({ error: 'not_seated' }, 403);

    const { error: dealErr } = await admin.rpc('deal_hand', { p_table_id: table_id });
    if (dealErr) return json({ error: dealErr.message }, 400);

    const { data: state } = await admin.from('online_hand_state').select('*').eq('table_id', table_id).single();
    if (!state) return json({ error: 'state_missing_after_deal' }, 500);

    const publicChannel = admin.channel(`table:${table_id}:public`);
    await publicChannel.send({
      type: 'broadcast', event: 'state',
      payload: {
        phase: state.phase, board: state.board, pot: state.pot, current_seat: state.current_seat,
        dealer_seat: state.dealer_seat, bets: state.bets, hand_no: state.hand_no, seat_order: state.seat_order,
        folded: state.folded, all_in: state.all_in, last_raise_size: state.last_raise_size,
      },
    });

    // Eigene Hole Cards nur auf dem jeweils privaten Kanal — nie zusammen in
    // einer Nachricht, die mehrere Sitze empfangen könnten.
    const seatOrder: number[] = state.seat_order || [];
    for (const seatNo of seatOrder) {
      const seatChannel = admin.channel(`table:${table_id}:seat:${seatNo}`, { config: { private: true } });
      await seatChannel.send({ type: 'broadcast', event: 'hole_cards', payload: { cards: state.hole_cards[String(seatNo)] } });
    }

    return json({ ok: true, hand_no: state.hand_no });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
