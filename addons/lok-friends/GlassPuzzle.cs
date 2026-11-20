using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using Random = System.Random;

namespace LokFriends
{
    public static class GlassPuzzle
    {
        private const string TargetLetters = "DFHIJMPQRSUVXZ";
        // Candidate seeds whose certificates passed with the pinned Unity
        // player. Only used if the random search exhausts its budget.
        private static readonly int[][] CertifiedSeeds = {
            new[] { 1002897798, 1498044246 },
            new[] { 610783965, 368853226, 1397622145 },
            new[] { 1649316166, 867932563, 2128155929 }
        };
        private static Plan active;

        private sealed class Move
        {
            public string Word;
            public readonly char[] Targets;

            public Move(string word, params char[] targets)
            {
                Word = word;
                Targets = targets;
            }
        }

        private sealed class Plan
        {
            public readonly List<Move> Moves = new List<Move>();
            public int LastStep;
        }

        private sealed class CandidateRejected : Exception { }

        public static GenLevel Generate(int seed)
        {
            Random random = new Random(seed);
            int turns = random.Next(7, 10);
            UnityEngine.Random.State previous = UnityEngine.Random.state;
            try
            {
                for (int attempt = 0; attempt < 12; attempt++)
                {
                    GenLevel level = TryGenerate(turns, random.Next());
                    if (level != null)
                        return level;
                }

                int[] seeds = CertifiedSeeds[turns - 7];
                int first = random.Next(seeds.Length);
                for (int i = 0; i < seeds.Length; i++)
                {
                    GenLevel level = TryGenerate(turns, seeds[(first + i) % seeds.Length]);
                    if (level != null)
                        return level;
                }
            }
            finally
            {
                UnityEngine.Random.state = previous;
            }
            throw new InvalidOperationException("No certified glass puzzle could be generated.");
        }

        private static GenLevel TryGenerate(int turns, int seed)
        {
            Plan plan = MakePlan(turns, seed);
            active = plan;
            try
            {
                LOKGenerator.SetSeed(seed);
                // Profile 0 lets the plan set the length without forcing BE or X corners.
                GenLevel level = LOKGenerator.GenerateLevel(0, true, true, true, false, false);
                return Certify(level, plan) ? level : null;
            }
            catch (CandidateRejected)
            {
                return null;
            }
            finally
            {
                active = null;
            }
        }

        private static Plan MakePlan(int turns, int seed)
        {
            var random = new Random(seed);
            int doubles = random.Next(1, 4);
            int shielded = random.Next(2, Math.Min(4, Math.Min(turns - doubles, (turns + doubles) / 2)) + 1);
            int extra = random.Next(shielded, Math.Min(shielded * 3,
                Math.Min(turns - doubles, turns + doubles - shielded)) + 1);
            int targetCount = turns + doubles - extra;
            var letters = TargetLetters.ToList();
            Shuffle(letters, random);
            var pending = new List<Move>();
            for (int i = 0; i < 2 * doubles; i += 2)
                pending.Add(new Move("TLAK", letters[i], letters[i + 1]));
            for (int i = 2 * doubles; i < targetCount; i++)
                pending.Add(new Move("TA", letters[i]));

            var protectedLetters = letters.Take(targetCount).ToList();
            Shuffle(protectedLetters, random);
            protectedLetters.RemoveRange(shielded, protectedLetters.Count - shielded);
            var layers = new int[shielded];
            for (int i = 0; i < shielded; i++)
            {
                layers[i] = 1;
                pending.Add(new Move("TA", protectedLetters[i]));
            }
            for (int i = shielded; i < extra; i++)
            {
                var available = Enumerable.Range(0, shielded).Where(index => layers[index] < 3).ToList();
                int target = available[random.Next(available.Count)];
                layers[target]++;
                pending.Add(new Move("TA", protectedLetters[target]));
            }

            // The native reverse builder introduces each TLAK pair together.
            // Its additional hits can be inserted after their targets exist.
            var plan = new Plan();
            var introduced = new HashSet<char>();
            int newMoves = targetCount - doubles;
            var firstHits = new HashSet<Move>(pending.Take(newMoves));
            while (pending.Count > 0)
            {
                var available = pending.FindAll(move => firstHits.Contains(move) ||
                    introduced.Contains(move.Targets[0]));
                Move next = available[random.Next(available.Count)];
                plan.Moves.Add(next);
                pending.Remove(next);
                foreach (char target in next.Targets)
                    introduced.Add(target);
            }

            // A single O permits LOK while making LOLO and OLKO impossible.
            var optionalLok = plan.Moves.Skip(1).Where(move => move.Word == "TA").ToList();
            if (optionalLok.Count != 0 && random.Next(2) == 0)
                optionalLok[random.Next(optionalLok.Count)].Word = "LOK";
            return plan;
        }

        private static void Shuffle<T>(IList<T> items, Random random)
        {
            for (int i = items.Count - 1; i > 0; i--)
            {
                int other = random.Next(i + 1);
                T first = items[i];
                items[i] = items[other];
                items[other] = first;
            }
        }

        public static int SelectCycles(int original)
        {
            return active == null ? original : active.Moves.Count;
        }

        public static void GuardStep(int step)
        {
            if (active == null)
                return;
            // The native step already tries 100 layouts. A repeated call means
            // those attempts never advanced its step counter.
            if (step <= active.LastStep || step > active.Moves.Count)
                throw new CandidateRejected();
            active.LastStep = step;
        }

        public static int SelectWord(int min, int max, int step, List<string> words)
        {
            return active == null ? UnityEngine.Random.Range(min, max) :
                words.IndexOf(active.Moves[step - 1].Word);
        }

        public static int SelectTargetCount(int min, int max)
        {
            return active == null ? UnityEngine.Random.Range(min, max) : 1;
        }

        public static Vector2Int SelectPivot(GenLevelBoard board, int previousStep)
        {
            if (active != null && previousStep > 0)
            {
                // Later words can cross a previous word after it goes black.
                // A glass target can still be white, so it cannot be the pivot.
                var letters = board.tiles.Where(tile => tile.solveTime == previousStep &&
                    "LTKAO".IndexOf(tile.value[0]) >= 0).ToList();
                if (letters.Count > 0)
                    return letters[UnityEngine.Random.Range(0, letters.Count)].pos;
            }
            return board.GetRandomBlackTilePos(previousStep);
        }

        public static void PlaceTarget(GenLevelBoard board, Vector2Int position, string value,
            int step, bool solved, int weight, int ordinal)
        {
            if (active != null)
            {
                char letter = active.Moves[step - 1].Targets[ordinal];
                GenLevelTile existing = board.tiles.Find(tile => tile.value[0] == letter);
                if (existing != null)
                {
                    existing.value += "*";
                    return;
                }
                value = letter.ToString();
            }
            board.AddTile(position, value, step, solved, weight);
        }

        private static bool Certify(GenLevel level, Plan plan)
        {
            GenLevelBoard board = level.GetLastBoard();
            int turns = plan.Moves.Count;
            if (level.steps.Count != turns || board.maxx - board.minx > 14 || board.maxy - board.miny > 14)
                return false;

            var tiles = new Dictionary<Vector2Int, GenLevelTile>();
            var health = new Dictionary<Vector2Int, int>();
            var targets = new Dictionary<char, Vector2Int>();
            int targetWork = 0, ls = 0, ks = 0, os = 0, protectedTiles = 0;
            foreach (GenLevelTile tile in board.tiles)
            {
                if (tiles.ContainsKey(tile.pos) || string.IsNullOrEmpty(tile.value))
                    return false;
                tiles.Add(tile.pos, tile);
                health.Add(tile.pos, tile.value.Length);
                char letter = tile.value[0];
                if (TargetLetters.IndexOf(letter) >= 0)
                {
                    if (targets.ContainsKey(letter) || tile.value.Length > 4 ||
                        tile.value.Skip(1).Any(layer => layer != '*'))
                        return false;
                    targets.Add(letter, tile.pos);
                    targetWork += tile.value.Length;
                    if (tile.value.Length > 1) protectedTiles++;
                }
                else
                {
                    if (tile.value.Length != 1 || "LTKAO".IndexOf(letter) < 0)
                        return false;
                    if (letter == 'L') ls++;
                    if (letter == 'K') ks++;
                    if (letter == 'O') os++;
                }
            }

            // Each target is unique. TA and LOK do at most one unit of work
            // per move; TLAK can do two but consumes one L and one K. A lone O
            // either costs a target hit or spends another L/K pair via LOK.
            int lowerBound = targetWork - Math.Min(ls, ks) + os;
            if (os > 1 || lowerBound != turns || protectedTiles < 2)
                return false;

            for (int index = 0; index < turns; index++)
            {
                Move move = plan.Moves[index];
                var wordTiles = board.tiles.Where(tile =>
                    tile.solveTime == index + 1 && "LTKAO".IndexOf(tile.value[0]) >= 0)
                    .OrderBy(tile => tile.pos.x).ThenBy(tile => tile.pos.y).ToList();
                if (wordTiles.Count != move.Word.Length ||
                    !TryConsumeWord(wordTiles, move.Word, health))
                    return false;
                if (move.Word == "LOK" && !TouchesOtherStep(wordTiles, tiles))
                    return false;
                if (move.Targets.Length == 2)
                {
                    Vector2Int first, second;
                    if (!targets.TryGetValue(move.Targets[0], out first) ||
                        !targets.TryGetValue(move.Targets[1], out second) ||
                        !ClearLine(first, second, health))
                        return false;
                }
                foreach (char target in move.Targets)
                {
                    Vector2Int position;
                    if (!targets.TryGetValue(target, out position) || health[position] <= 0)
                        return false;
                    health[position]--;
                }
            }
            return health.Values.All(hits => hits == 0);
        }

        private static bool TryConsumeWord(List<GenLevelTile> tiles, string word,
            Dictionary<Vector2Int, int> health)
        {
            string letters = string.Concat(tiles.Select(tile => tile.value));
            if (letters != word && new string(letters.Reverse().ToArray()) != word)
                return false;
            Vector2Int first = tiles[0].pos, last = tiles[tiles.Count - 1].pos;
            if ((first.x == last.x) == (first.y == last.y))
                return false;
            var direction = new Vector2Int(Math.Sign(last.x - first.x), Math.Sign(last.y - first.y));
            for (int i = 0; i < tiles.Count; i++)
            {
                Vector2Int start = tiles[i].pos;
                if (health[start] != 1)
                    return false;
                if (i + 1 != tiles.Count)
                {
                    Vector2Int end = tiles[i + 1].pos;
                    if ((end.x - start.x) * direction.y != (end.y - start.y) * direction.x ||
                        !ClearLine(start, end, health))
                        return false;
                }
            }
            foreach (GenLevelTile tile in tiles)
                health[tile.pos]--;
            return true;
        }

        private static bool ClearLine(Vector2Int start, Vector2Int end, Dictionary<Vector2Int, int> health)
        {
            if ((start.x == end.x) == (start.y == end.y))
                return false;
            var direction = new Vector2Int(Math.Sign(end.x - start.x), Math.Sign(end.y - start.y));
            for (Vector2Int position = start + direction; position != end; position += direction)
            {
                int hits;
                if (health.TryGetValue(position, out hits) && hits > 0)
                    return false;
            }
            return true;
        }

        private static bool TouchesOtherStep(List<GenLevelTile> word,
            Dictionary<Vector2Int, GenLevelTile> tiles)
        {
            Vector2Int[] directions = { Vector2Int.left, Vector2Int.right, Vector2Int.up, Vector2Int.down };
            foreach (GenLevelTile letter in word)
            {
                foreach (Vector2Int direction in directions)
                {
                    GenLevelTile neighbour;
                    if (tiles.TryGetValue(letter.pos + direction, out neighbour) &&
                        (TargetLetters.IndexOf(neighbour.value[0]) >= 0 ||
                        neighbour.solveTime != letter.solveTime))
                        return true;
                }
            }
            return false;
        }
    }
}
