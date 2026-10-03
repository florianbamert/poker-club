// =====================================================================
// Reine Spiellogik, ohne DB- oder Netzwerk-Zugriff — darum einfach lokal
// mit Node/Deno testbar. evaluate5/evaluate7/compareHandArrays sind
// wortwörtlich aus poker-club.html übernommen (dort ab Zeile ~8158),
// damit Online-Spiel und Live-Erfassung/Replay garantiert dieselbe
// Hand-Bewertung verwenden — keine zweite, potenziell abweichende
// Implementierung (siehe "Bekannte Bugs"-Dokument: Live-vs-Replay-
// Duplikation war schon mal die Ursache echter Bugs).
//
// Karten-Format identisch zur App: Rang + Farb-Symbol, z. B. 'A♠', 'T♦'.
// =====================================================================

export const RANK_VALUES: Record<string, number> = {
  '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7, '8': 8, '9': 9,
  'T': 10, 'J': 11, 'Q': 12, 'K': 13, 'A': 14,
};

export function combinations<T>(arr: T[], k: number): T[][] {
  const result: T[][] = [];
  function helper(start: number, combo: T[]) {
    if (combo.length === k) { result.push(combo.slice()); return; }
    for (let i = start; i < arr.length; i++) { combo.push(arr[i]); helper(i + 1, combo); combo.pop(); }
  }
  helper(0, []);
  return result;
}

export function evaluate5(cards: string[]): number[] {
  const ranks = cards.map(c => RANK_VALUES[c.slice(0, -1)]).sort((a, b) => b - a);
  const suits = cards.map(c => c.slice(-1));
  const isFlush = suits.every(s => s === suits[0]);
  const uniqueRanks = [...new Set(ranks)];
  let isStraight = false, straightHigh = 0;
  if (uniqueRanks.length === 5) {
    if (uniqueRanks[0] - uniqueRanks[4] === 4) { isStraight = true; straightHigh = uniqueRanks[0]; }
    else if (uniqueRanks.join(',') === '14,5,4,3,2') { isStraight = true; straightHigh = 5; }
  }
  const countMap: Record<number, number> = {};
  ranks.forEach(r => countMap[r] = (countMap[r] || 0) + 1);
  const groups = Object.entries(countMap).map(([r, c]) => ({ rank: Number(r), count: c as number }))
    .sort((a, b) => b.count - a.count || b.rank - a.rank);
  if (isStraight && isFlush) return [8, straightHigh];
  if (groups[0].count === 4) return [7, groups[0].rank, groups[1].rank];
  if (groups[0].count === 3 && groups[1] && groups[1].count >= 2) return [6, groups[0].rank, groups[1].rank];
  if (isFlush) return [5, ...ranks];
  if (isStraight) return [4, straightHigh];
  if (groups[0].count === 3) return [3, groups[0].rank, ...groups.slice(1).map(g => g.rank)];
  if (groups[0].count === 2 && groups[1] && groups[1].count === 2) return [2, groups[0].rank, groups[1].rank, groups[2].rank];
  if (groups[0].count === 2) return [1, groups[0].rank, ...groups.slice(1).map(g => g.rank)];
  return [0, ...ranks];
}

export function evaluate7(cards: string[]): number[] {
  let best: number[] = [-1];
  combinations(cards, 5).forEach(c => {
    const val = evaluate5(c);
    if (compareHandArrays(val, best) > 0) best = val;
  });
  return best;
}

export function compareHandArrays(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const av = a[i] || 0, bv = b[i] || 0;
    if (av !== bv) return av - bv;
  }
  return 0;
}

function round2(n: number): number { return Math.round((n + Number.EPSILON) * 100) / 100; }

// =====================================================================
// Mehrweg-Betting-State-Machine (2–10 Sitze). Ersetzt die ursprüngliche
// Heads-up-only Variante. Kernidee gegenüber Heads-up: statt eines fest
// verdrahteten "Gegner"-Sitzes gibt es `seat_order` — die bei deal_hand()
// EINMAL festgelegte, aufsteigend sortierte Liste der an dieser Hand
// beteiligten Sitze. Alle Positions-/Reihenfolge-Berechnungen (wer ist
// nach wem dran, wer ist SB/BB, wer zeigt beim Showdown zuerst) laufen
// als Rotation über dieses Array.
// =====================================================================

export type Phase = 'waiting' | 'preflop' | 'flop' | 'turn' | 'river' | 'showdown' | 'done';

export interface HandState {
  phase: Phase;
  dealer_seat: number;
  seat_order: number[];       // fix für die ganze Hand: besetzte Sitze, aufsteigend nach seat_no
  board: string[];
  deck: string[];
  pot: number;                // Summe aller Beiträge dieser Hand (für die Anzeige)
  current_seat: number;
  bets: Record<string, number>;          // Einsätze DIESER Setzrunde
  acted: Record<string, boolean>;        // wer in dieser Setzrunde schon agiert hat
  folded: Record<string, boolean>;
  all_in: Record<string, boolean>;
  contributions: Record<string, number>; // Gesamtbeitrag zum Pot über die GANZE Hand (für Side-Pots)
  last_raise_size: number;
  last_aggressor: number | null;         // wer zuletzt freiwillig gesetzt/erhöht hat (nie durch Blinds gesetzt)
}

export interface SeatInfo { seat_no: number; stack: number; }
export type ActionType = 'fold' | 'check' | 'call' | 'bet' | 'raise';

export interface PotLayer { amount: number; eligibleSeats: number[]; }

export interface ApplyActionResult {
  error?: string;
  state?: HandState;
  stacks?: Record<string, number>;
  handOver?: boolean;
  pots?: PotLayer[]; // nur bei handOver=true durch Fold gesetzt (ein Pot an den letzten Übrigen)
}

function dealCards(deck: string[], n: number): { cards: string[]; rest: string[] } {
  return { cards: deck.slice(0, n), rest: deck.slice(n) };
}
function nextStreetCardCount(phase: Phase): number {
  if (phase === 'preflop') return 3; // Flop
  if (phase === 'flop') return 1;    // Turn
  if (phase === 'turn') return 1;    // River
  return 0;
}
function nextStreetName(phase: Phase): Phase {
  if (phase === 'preflop') return 'flop';
  if (phase === 'flop') return 'turn';
  if (phase === 'turn') return 'river';
  return 'showdown';
}

/** Nächster Sitz nach `from` in der Rotation, der weder gefoldet noch all-in
 * ist (also noch agieren kann). Fällt auf `from` zurück, falls niemand mehr
 * agieren kann (sollte von den Aufrufern vorher abgefangen werden). */
function nextActingSeat(order: number[], from: number, folded: Record<string, boolean>, allIn: Record<string, boolean>): number {
  const n = order.length;
  const idx = order.indexOf(from);
  for (let k = 1; k <= n; k++) {
    const cand = order[(idx + k) % n];
    if (!folded[cand] && !allIn[cand]) return cand;
  }
  return from;
}

/** Erster Sitz nach dem Dealer, der eine neue Strasse eröffnet — identisch
 * zu nextActingSeat, nur semantisch für den Strassenwechsel benannt. */
function firstActiveAfterDealer(order: number[], dealerSeat: number, folded: Record<string, boolean>, allIn: Record<string, boolean>): number {
  return nextActingSeat(order, dealerSeat, folded, allIn);
}

/** Baut Haupt-Pot + Side-Pots aus den kumulierten Beiträgen der ganzen Hand.
 * Klassischer Layer-Algorithmus: pro eindeutigem Beitrags-Niveau (meist durch
 * unterschiedlich hohe All-ins verursacht) eine Schicht, an der alle beteiligt
 * sind, die mindestens so viel eingezahlt haben — gewinnberechtigt für diese
 * Schicht sind aber nur die davon, die nicht gefoldet haben. */
export function buildPots(contributions: Record<string, number>, foldedSeats: Set<number>, seatOrder: number[]): PotLayer[] {
  const entries = seatOrder.map(s => ({ seat: s, amt: contributions[s] || 0 })).filter(e => e.amt > 0.0001);
  const levels = [...new Set(entries.map(e => e.amt))].sort((a, b) => a - b);
  const pots: PotLayer[] = [];
  let prev = 0;
  for (const level of levels) {
    const layerPer = level - prev;
    const contributors = entries.filter(e => e.amt >= level - 0.0001);
    const layerTotal = round2(layerPer * contributors.length);
    if (layerTotal > 0.0001) {
      const eligible = contributors.filter(e => !foldedSeats.has(e.seat)).map(e => e.seat);
      pots.push({ amount: layerTotal, eligibleSeats: eligible });
    }
    prev = level;
  }
  return pots;
}

/**
 * Reine Funktion: nimmt den aktuellen Zustand + eine Aktion, gibt den neuen
 * Zustand zurück. Macht KEINE DB-Zugriffe — darum problemlos mit Node testbar,
 * ohne Deno oder eine echte Datenbank zu brauchen.
 */
export function applyAction(
  state: HandState,
  seats: Record<string, SeatInfo>,
  actingSeat: number,
  action: ActionType,
  amount?: number,
): ApplyActionResult {
  if (!['preflop', 'flop', 'turn', 'river'].includes(state.phase)) {
    return { error: 'not_betting_phase' };
  }
  if (state.current_seat !== actingSeat) {
    return { error: 'not_your_turn' };
  }
  if (state.folded[actingSeat] || state.all_in[actingSeat]) {
    return { error: 'cannot_act' };
  }

  const bets = { ...state.bets };
  const acted = { ...state.acted };
  const folded = { ...state.folded };
  const allIn = { ...state.all_in };
  const contributions = { ...state.contributions };
  const stacks: Record<string, number> = {};
  for (const s of state.seat_order) stacks[s] = seats[s].stack;
  let pot = state.pot;
  let lastRaiseSize = state.last_raise_size;
  let lastAggressor = state.last_aggressor;

  const currentMaxBet = Math.max(0, ...state.seat_order.filter(s => !folded[s]).map(s => bets[s] || 0));
  const toCall = currentMaxBet - (bets[actingSeat] || 0);

  if (action === 'fold') {
    folded[actingSeat] = true;
    acted[actingSeat] = true;
  } else if (action === 'check') {
    if (toCall > 0.0001) return { error: 'cannot_check_facing_bet' };
    acted[actingSeat] = true;
  } else if (action === 'call') {
    if (toCall <= 0.0001) return { error: 'nothing_to_call' };
    const callAmt = Math.min(toCall, stacks[actingSeat]);
    bets[actingSeat] = round2((bets[actingSeat] || 0) + callAmt);
    contributions[actingSeat] = round2((contributions[actingSeat] || 0) + callAmt);
    stacks[actingSeat] = round2(stacks[actingSeat] - callAmt);
    pot = round2(pot + callAmt);
    acted[actingSeat] = true;
    if (stacks[actingSeat] <= 0.0001) allIn[actingSeat] = true;
  } else if (action === 'bet' || action === 'raise') {
    if (typeof amount !== 'number' || !Number.isFinite(amount)) return { error: 'invalid_amount' };
    const currentBet = bets[actingSeat] || 0;
    if (amount <= currentBet + 0.0001) return { error: 'invalid_amount' };
    const added = round2(amount - currentBet);
    if (added > stacks[actingSeat] + 0.0001) return { error: 'insufficient_stack' };
    const isAllIn = added >= stacks[actingSeat] - 0.0001;
    const minTotal = currentMaxBet + lastRaiseSize;
    if (amount < minTotal - 0.0001 && !isAllIn) return { error: 'raise_too_small' };
    const raiseSize = amount - currentMaxBet;
    bets[actingSeat] = round2(amount);
    contributions[actingSeat] = round2((contributions[actingSeat] || 0) + added);
    stacks[actingSeat] = round2(stacks[actingSeat] - added);
    pot = round2(pot + added);
    acted[actingSeat] = true;
    if (isAllIn) allIn[actingSeat] = true;
    if (raiseSize > 0.0001) {
      // Echte freiwillige Erhöhung (nicht nur ein verkürzter All-in-"Call" unter
      // dem bisherigen Gebot) — macht diesen Sitz zum neuen Showdown-Aggressor
      // und zwingt alle anderen noch aktiven Sitze zu einer erneuten Reaktion.
      lastAggressor = actingSeat;
      if (raiseSize > lastRaiseSize) lastRaiseSize = raiseSize;
      for (const s of state.seat_order) {
        if (s !== actingSeat && !folded[s] && !allIn[s]) acted[s] = false;
      }
    }
  } else {
    return { error: 'unknown_action' };
  }

  const liveSeats = state.seat_order.filter(s => !folded[s]);

  // Hand endet sofort, wenn nur noch ein Sitz übrig ist (alle anderen gefoldet)
  // — der volle Pot (inkl. der Beiträge der gefoldeten Sitze) geht ohne
  // Showdown an diesen Sitz.
  if (liveSeats.length === 1) {
    const winnerSeat = liveSeats[0];
    return {
      state: { ...state, bets, acted, folded, all_in: allIn, contributions, pot, last_raise_size: lastRaiseSize, last_aggressor: lastAggressor, phase: 'done', current_seat: winnerSeat },
      stacks,
      handOver: true,
      pots: [{ amount: pot, eligibleSeats: [winnerSeat] }],
    };
  }

  const seatsCanAct = liveSeats.filter(s => !allIn[s]);
  const newMaxBet = Math.max(0, ...liveSeats.map(s => bets[s] || 0));
  const allActed = seatsCanAct.every(s => acted[s]);
  const betsSettled = seatsCanAct.every(s => Math.abs((bets[s] || 0) - newMaxBet) < 0.0001);
  // Ist niemand mehr übrig, der agieren kann (alle live Sitze all-in bis auf
  // höchstens einen, der schon passend gesetzt hat), ist die Runde ebenfalls
  // fertig — .every() auf einem leeren Array ist per Definition true, das
  // deckt den Fall "alle bis auf den Aktuellen sind all-in" korrekt ab.
  const roundComplete = allActed && betsSettled;

  if (!roundComplete) {
    const next = nextActingSeat(state.seat_order, actingSeat, folded, allIn);
    return {
      state: { ...state, bets, acted, folded, all_in: allIn, contributions, pot, last_raise_size: lastRaiseSize, last_aggressor: lastAggressor, current_seat: next },
      stacks,
      handOver: false,
    };
  }

  // Setzrunde fertig. "seatsCanAct.length <= 1" deckt nicht nur den Fall ab, dass
  // ALLE live Sitze all-in sind, sondern auch: genau EIN Sitz hat noch Chips, hat
  // aber bereits passend gecallt/gecheckt — dann kann niemand mehr auf eine weitere
  // Aktion reagieren (alle anderen sind all-in), also sofort zum Showdown durchlaufen
  // statt noch eine sinnlose Setzrunde für einen einzelnen Spieler zu eröffnen.
  if (state.phase === 'river' || seatsCanAct.length <= 1) {
    // Restliche Board-Karten (falls All-in vor dem River) aufdecken, dann Showdown.
    let board = state.board.slice();
    let deck = state.deck.slice();
    let phase: Phase = state.phase;
    while (phase !== 'river' && phase !== 'showdown') {
      const n = nextStreetCardCount(phase);
      const { cards, rest } = dealCards(deck, n);
      board = board.concat(cards);
      deck = rest;
      phase = nextStreetName(phase);
    }
    return {
      state: { ...state, bets, acted, folded, all_in: allIn, contributions, pot, last_raise_size: lastRaiseSize, last_aggressor: lastAggressor, board, deck, phase: 'showdown', current_seat: actingSeat },
      stacks,
      handOver: false, // resolveMultiwayShowdown() wertet separat aus
    };
  }

  // Nächste Strasse: Karten aufdecken, Einsätze zurücksetzen, erster aktiver
  // Sitz nach dem Dealer beginnt.
  const { cards, rest } = dealCards(state.deck, nextStreetCardCount(state.phase));
  const newPhase = nextStreetName(state.phase);
  const firstToAct = firstActiveAfterDealer(state.seat_order, state.dealer_seat, folded, allIn);
  const newBets: Record<string, number> = {};
  for (const s of state.seat_order) newBets[s] = 0;
  return {
    state: {
      ...state,
      bets: newBets,
      acted: {},
      folded, all_in: allIn, contributions, pot,
      last_raise_size: lastRaiseSize,
      last_aggressor: lastAggressor,
      board: state.board.concat(cards),
      deck: rest,
      phase: newPhase,
      current_seat: firstToAct,
    },
    stacks,
    handOver: false,
  };
}

/**
 * Automatische Mehrweg-Showdown-Auswertung (2–10 Spieler), inkl. Side-Pots.
 *
 * Regel (so vom Club-Admin festgelegt, entspricht der üblichen Cardroom-
 * Etikette): NIEMAND muss sein Blatt freiwillig zeigen — der Server kennt
 * die Karten ohnehin und wertet vollautomatisch aus, ohne eine Show/Muck-
 * Eingabe der Spieler abzuwarten. Aufgedeckt (für alle sichtbar) werden nur:
 *   (a) wer zuletzt freiwillig gesetzt/erhöht hat (last_aggressor) — die
 *       klassische Regel "wer zuletzt aggressiv war, zeigt zuerst", hier
 *       automatisch statt als Spieler-Entscheidung umgesetzt, und
 *   (b) wer tatsächlich (mindestens) einen Pot oder Side-Pot gewinnt.
 * Ein schlechteres Blatt bleibt verdeckt — "wer sowieso schlechter ist,
 * muss nicht zeigen".
 */
export function resolveMultiwayShowdown(
  holeCards: Record<string, string[]>,
  board: string[],
  seatOrder: number[],
  folded: Record<string, boolean>,
  contributions: Record<string, number>,
  lastAggressor: number | null,
): { payouts: Record<string, number>; revealSeats: number[]; values: Record<string, number[]> } {
  const foldedSet = new Set(seatOrder.filter(s => folded[s]));
  const pots = buildPots(contributions, foldedSet, seatOrder);
  const liveSeats = seatOrder.filter(s => !folded[s]);
  const values: Record<string, number[]> = {};
  for (const s of liveSeats) values[s] = evaluate7(holeCards[s].concat(board));

  const payouts: Record<string, number> = {};
  const revealSet = new Set<number>();
  if (lastAggressor != null && !folded[lastAggressor]) revealSet.add(lastAggressor);

  for (const pot of pots) {
    if (pot.eligibleSeats.length === 0) continue; // alle Beitragenden dieser Schicht haben gefoldet
    let bestVal: number[] | null = null;
    for (const s of pot.eligibleSeats) {
      if (!bestVal || compareHandArrays(values[s], bestVal) > 0) bestVal = values[s];
    }
    const winners = pot.eligibleSeats.filter(s => compareHandArrays(values[s], bestVal!) === 0);
    winners.forEach(s => revealSet.add(s));
    const share = Math.floor((pot.amount / winners.length) * 100) / 100;
    let distributed = 0;
    winners.forEach((s, i) => {
      const amt = i === winners.length - 1 ? round2(pot.amount - distributed) : share; // Rest-Rappen an den letzten
      payouts[s] = round2((payouts[s] || 0) + amt);
      distributed = round2(distributed + amt);
    });
  }

  return { payouts, revealSeats: [...revealSet], values };
}
