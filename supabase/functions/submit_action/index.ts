// Phase 0 — submit_action
// Nimmt eine Spieler-Absicht entgegen (fold/check/call/bet/raise), validiert
// sie serverseitig (siehe applyAction in _shared/poker.ts) und schreibt den
// neuen Zustand. Bei Showdown wird der Gewinner direkt hier ermittelt und
// der Pot (inkl. Side-Pots) ausgezahlt.
//
// Mehrweg (2–10 Sitze): state.seat_order (von deal_hand() gesetzt) ersetzt
// die frühere feste [0,1]-Annahme. Showdown-Regel: niemand muss freiwillig
// zeigen — resolveMultiwayShowdown() deckt automatisch nur den letzten
// Aggressor sowie tatsächliche Pot-/Side-Pot-Gewinner auf, alle anderen
// bleiben verdeckt (siehe dortiger Kommentar).
//
// Bekannte Vereinfachung für Phase 0 (siehe Architektur-Spezifikation,
// "Offene Risiken"): Das Lesen+Schreiben läuft NICHT in einer einzigen
// Postgres-Transaktion, sondern optimistisch — der UPDATE greift nur, wenn
// `updated_at` seit dem Lesen nicht verändert wurde. Weil immer nur der
// Sitz am Zug schreiben darf (current_seat-Check), ist das Risiko einer
// echten Kollision gering, aber vor Phase 1 sollte das durch eine atomare
// SQL-Funktion ersetzt werden.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { applyAction, resolveMultiwayShowdown, RANK_VALUES, type ActionType, type HandState } from '../_shared/poker.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

// CORS: der Browser (GitHub Pages) ruft die Funktion direkt auf und schickt vorher eine OPTIONS-Anfrage
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// 7-2 Game aktiv? Die Option steht in online_tables.options (falls die Spalte existiert), sonst im Club-Datenblock
async function sevenDeuceEnabled(admin: ReturnType<typeof createClient>, tableId: string): Promise<{ on: boolean; bb: number }> {
  let bb = 0, clubId: string | null = null, opt: any = null, haveOpt = false;
  const r1 = await admin.from('online_tables').select('big_blind, club_id, options').eq('id', tableId).maybeSingle();
  if (!r1.error && r1.data) { bb = Number(r1.data.big_blind); clubId = r1.data.club_id; opt = r1.data.options; haveOpt = true; }
  else {
    const r2 = await admin.from('online_tables').select('big_blind, club_id').eq('id', tableId).maybeSingle();
    if (r2.data) { bb = Number(r2.data.big_blind); clubId = r2.data.club_id; }
  }
  if ((!haveOpt || !opt) && clubId) {
    const cd = await admin.from('club_data').select('data').eq('club_id', clubId).maybeSingle();
    const o = cd.data && cd.data.data && cd.data.data.onlineTableOptions ? cd.data.data.onlineTableOptions[tableId] : null;
    if (o) opt = o;
  }
  return { on: !!(opt && opt.sevenDeuceGame), bb };
}
function isSevenDeuce(cards: string[] | undefined): boolean {
  if (!cards || cards.length !== 2) return false;
  const r = cards.map(c => RANK_VALUES[c.slice(0, -1)]).sort((a, b) => a - b);
  return r[0] === 2 && r[1] === 7;
}

// Zugzeit: 15 s pro Entscheid (+1.5 s Netzwerk-Toleranz); Timebank: +45 s, einmal pro 50 Hände und Sitz
const TURN_MS = 15000, GRACE_MS = 1500, TB_EXTRA_MS = 45000, TB_EVERY_HANDS = 50;
const BETTING_PHASES = ['preflop', 'flop', 'turn', 'river'];

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  try {
    const { table_id, action: actionIn, amount } = await req.json() as { table_id: string; action: ActionType | 'timeout' | 'timebank'; amount?: number };
    let action = actionIn as ActionType;
    if (!table_id || !actionIn) return json({ error: 'table_id oder action fehlt' }, 400);

    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: stateRow } = await admin.from('online_hand_state').select('*').eq('table_id', table_id).single();
    if (!stateRow) return json({ error: 'no_hand' }, 400);

    const seatOrder: number[] = stateRow.seat_order || [];
    if (seatOrder.length < 2) return json({ error: 'table_not_ready' }, 400);

    const { data: seatsRaw } = await admin.from('online_seats').select('seat_no, user_id, stack').eq('table_id', table_id).in('seat_no', seatOrder);
    if (!seatsRaw || seatsRaw.length !== seatOrder.length) return json({ error: 'table_not_ready' }, 400);
    const mySeatRow = seatsRaw.find(s => s.user_id === user.id);
    if (!mySeatRow) return json({ error: 'not_seated' }, 403);
    let actingSeat = mySeatRow.seat_no as number;
    const seats: Record<string, { seat_no: number; stack: number }> = {};
    for (const s of seatsRaw) seats[s.seat_no] = { seat_no: s.seat_no, stack: Number(s.stack) };

    const state: HandState = {
      phase: stateRow.phase, dealer_seat: stateRow.dealer_seat, seat_order: seatOrder,
      board: stateRow.board, deck: stateRow.deck, pot: Number(stateRow.pot), current_seat: stateRow.current_seat,
      bets: stateRow.bets, acted: stateRow.acted, folded: stateRow.folded, all_in: stateRow.all_in || {},
      contributions: stateRow.contributions || {}, last_raise_size: Number(stateRow.last_raise_size),
      last_aggressor: stateRow.last_aggressor ?? null,
    };

    // Zeitkontrolle (benötigt chipmate_online_timebank.sql: Spalten turn_deadline / timebank_last_hand)
    const hasDeadlineCol = 'turn_deadline' in stateRow;
    if (actionIn === 'timebank') {
      if (!hasDeadlineCol) return json({ error: 'timebank_not_supported' }, 400);
      if (stateRow.current_seat !== actingSeat || !BETTING_PHASES.includes(stateRow.phase)) return json({ error: 'not_your_turn' }, 400);
      const { data: tb, error: tbErr } = await admin.from('online_seats').select('timebank_last_hand').eq('table_id', table_id).eq('seat_no', actingSeat).maybeSingle();
      if (tbErr) return json({ error: 'timebank_not_supported' }, 400);
      const last = tb ? tb.timebank_last_hand : null;
      if (last != null && Number(stateRow.hand_no) - Number(last) < TB_EVERY_HANDS) {
        return json({ error: 'timebank_unavailable', hands_left: TB_EVERY_HANDS - (Number(stateRow.hand_no) - Number(last)) }, 400);
      }
      const curDl = stateRow.turn_deadline ? Date.parse(stateRow.turn_deadline) : Date.now();
      const newDl = Math.max(Date.now(), curDl) + TB_EXTRA_MS;
      await admin.from('online_seats').update({ timebank_last_hand: Number(stateRow.hand_no) }).eq('table_id', table_id).eq('seat_no', actingSeat);
      await admin.from('online_hand_state').update({ turn_deadline: new Date(newDl).toISOString() }).eq('table_id', table_id);
      return json({ ok: true, remaining_ms: Math.max(0, newDl - Date.now() - GRACE_MS) });
    }
    if (actionIn === 'timeout') {
      // Jeder Sitz am Tisch darf melden, dass der Spieler am Zug überfällig ist — der Server prüft selbst und foldet.
      if (!hasDeadlineCol) return json({ error: 'timeout_not_supported' }, 400);
      if (!BETTING_PHASES.includes(stateRow.phase) || stateRow.current_seat == null) return json({ error: 'no_turn' }, 400);
      const dl = stateRow.turn_deadline ? Date.parse(stateRow.turn_deadline) : NaN;
      if (!isFinite(dl)) return json({ error: 'no_deadline' }, 400);
      const rem = dl - Date.now();
      if (rem > 0) return json({ ok: false, error: 'not_expired', remaining_ms: Math.max(0, rem - GRACE_MS) });
      actingSeat = stateRow.current_seat as number;
      action = 'fold';
    }

    const result = applyAction(state, seats, actingSeat, action, amount);
    if (result.error) return json({ error: result.error }, 400);

    const newState = result.state!;
    const newStacks = result.stacks!;

    // Aktionsprotokoll (fürs Speichern der Hand im Club): nur wenn die Spalte "actions" existiert
    const hasActionsCol = 'actions' in stateRow;
    const actionLog: Array<Record<string, unknown>> = hasActionsCol && Array.isArray(stateRow.actions) ? stateRow.actions.slice() : [];
    {
      const betsBefore = (stateRow.bets || {}) as Record<string, number>;
      const maxBet = Math.max(0, ...Object.values(betsBefore).map(Number));
      const myBetBefore = Number(betsBefore[String(actingSeat)] || 0);
      let logAmount: number | null = null;
      if (action === 'bet' || action === 'raise') logAmount = Number(amount);
      else if (action === 'call') logAmount = Math.min(maxBet, myBetBefore + seats[actingSeat].stack);
      actionLog.push({ seat: actingSeat, street: stateRow.phase, action, amount: logAmount });
    }

    // Optimistischer Schreibschutz: nur anwenden, wenn seit dem Lesen niemand
    // anders geschrieben hat.
    const { data: written, error: updateErr } = await admin
      .from('online_hand_state')
      .update({
        phase: newState.phase, board: newState.board, deck: newState.deck, pot: newState.pot,
        current_seat: newState.current_seat, bets: newState.bets, acted: newState.acted,
        folded: newState.folded, all_in: newState.all_in, contributions: newState.contributions,
        last_raise_size: newState.last_raise_size, last_aggressor: newState.last_aggressor,
        ...(hasActionsCol ? { actions: actionLog } : {}),
        ...(hasDeadlineCol ? { turn_deadline: (result.handOver || newState.phase === 'showdown') ? null : new Date(Date.now() + TURN_MS + GRACE_MS).toISOString() } : {}),
        updated_at: new Date().toISOString(),
      })
      .eq('table_id', table_id)
      .eq('updated_at', stateRow.updated_at)
      .select()
      .maybeSingle();
    if (updateErr) return json({ error: updateErr.message }, 500);
    if (!written) return json({ error: 'state_changed_meanwhile', retry: true }, 409);

    for (const seatNo of seatOrder) {
      if (newStacks[seatNo] !== seats[seatNo].stack) {
        await admin.from('online_seats').update({ stack: newStacks[seatNo] }).eq('table_id', table_id).eq('seat_no', seatNo);
      }
    }

    let handFinished = false;
    let payouts: Record<string, number> = {};
    let revealSeats: number[] = [];

    if (result.handOver) {
      // Durch Fold entschieden: der letzte Übrige bekommt den ganzen Pot ohne Showdown.
      handFinished = true;
      for (const pot of result.pots!) {
        for (const s of pot.eligibleSeats) payouts[s] = (payouts[s] || 0) + pot.amount;
      }
    } else if (newState.phase === 'showdown') {
      const sd = resolveMultiwayShowdown(
        stateRow.hole_cards, newState.board, seatOrder, newState.folded, newState.contributions, newState.last_aggressor,
      );
      payouts = sd.payouts;
      revealSeats = sd.revealSeats;
      handFinished = true;
    }

    // 7-2 Game: Gewinner mit 7-2 (Hole Cards) erhält von jedem anderen Spieler bis zu 2 BB (max. dessen Reststack)
    let sevenDeuce: { winner_seat: number; payments: Record<string, number>; total: number } | null = null;
    if (handFinished) {
      const sd = await sevenDeuceEnabled(admin, table_id);
      if (sd.on && sd.bb > 0) {
        const winnerSeat = Object.keys(payouts).map(Number).find(s => payouts[s] > 0.0001 && isSevenDeuce(stateRow.hole_cards[String(s)]));
        if (winnerSeat !== undefined) {
          const payments: Record<string, number> = {};
          for (const s of seatOrder) {
            if (s === winnerSeat) continue;
            const stackAfter = (newStacks[s] ?? seats[s].stack) + (payouts[s] || 0);
            const pay = Math.min(2 * sd.bb, stackAfter);
            if (pay > 0.0001) payments[String(s)] = Math.round(pay * 100) / 100;
          }
          const total = Math.round(Object.values(payments).reduce((a, b) => a + b, 0) * 100) / 100;
          if (total > 0.0001) {
            sevenDeuce = { winner_seat: winnerSeat, payments, total };
            if (!revealSeats.includes(winnerSeat)) revealSeats.push(winnerSeat);   // 7-2 muss gezeigt werden, um den Bounty zu kassieren
          }
        }
      }
      for (const seatNo of seatOrder) {
        const sn = Number(seatNo);
        const amt = payouts[sn] || 0;
        const delta = sevenDeuce ? (sn === sevenDeuce.winner_seat ? sevenDeuce.total : -(sevenDeuce.payments[String(sn)] || 0)) : 0;
        if (amt > 0.0001 || Math.abs(delta) > 0.0001) {
          const base = newStacks[sn] ?? seats[sn].stack;
          await admin.from('online_seats').update({ stack: Math.round((base + amt + delta) * 100) / 100 }).eq('table_id', table_id).eq('seat_no', sn);
        }
      }
      // Nur die hole_cards der tatsächlich aufgedeckten Sitze (Aggressor + echte
      // Gewinner) landen in der Historie/im Broadcast — ein schlechteres Blatt
      // bleibt für immer verdeckt, wie am echten Tisch.
      const revealedHoleCards: Record<string, string[]> = {};
      for (const s of revealSeats) revealedHoleCards[s] = stateRow.hole_cards[String(s)];
      await admin.from('online_hand_history').insert({
        table_id, hand_no: stateRow.hand_no,
        summary: {
          board: newState.board, revealed_hole_cards: revealedHoleCards, payouts, phase_ended: newState.phase,
          // Zusatzdaten fürs Übernehmen in die gespeicherten Hände (Replay)
          actions: actionLog, seat_order: seatOrder, dealer_seat: stateRow.dealer_seat,
          contributions: newState.contributions, seven_deuce: sevenDeuce,
          start_stacks: Object.fromEntries(seatOrder.map(sn => [String(sn), (newStacks[sn] ?? seats[sn].stack) + Number((newState.contributions || {})[String(sn)] || 0)])),
          pot_total: Object.values(newState.contributions || {}).reduce((a: number, b) => a + Number(b), 0),
        },
      });
      await admin.from('online_hand_state').update({ phase: 'done', pot: 0, revealed_hole_cards: revealedHoleCards }).eq('table_id', table_id);

      const publicChannel = admin.channel(`table:${table_id}:public`);
      await publicChannel.send({
        type: 'broadcast', event: 'state',
        payload: {
          phase: 'done', board: newState.board, pot: 0, current_seat: newState.current_seat, bets: newState.bets,
          folded: newState.folded, all_in: newState.all_in,
          dealer_seat: newState.dealer_seat, hand_no: stateRow.hand_no, last_action: { seat: actingSeat, action, amount },
          hand_over: true, payouts, seven_deuce: sevenDeuce,
          // Beim Showdown werden nur die aufgedeckten Hände öffentlich — kein Leck,
          // sondern dieselbe Etikette wie am echten Tisch (siehe resolveMultiwayShowdown).
          revealed_hole_cards: revealedHoleCards,
        },
      });
    } else {
      const publicChannel = admin.channel(`table:${table_id}:public`);
      await publicChannel.send({
        type: 'broadcast', event: 'state',
        payload: {
          phase: newState.phase, board: newState.board, pot: newState.pot, current_seat: newState.current_seat,
          bets: newState.bets, folded: newState.folded, all_in: newState.all_in, last_raise_size: newState.last_raise_size,
          dealer_seat: newState.dealer_seat, hand_no: stateRow.hand_no, last_action: { seat: actingSeat, action, amount }, hand_over: false, turn_ms: TURN_MS,
        },
      });
    }

    return json({ ok: true, phase: handFinished ? 'done' : newState.phase, hand_over: handFinished, payouts });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
