using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using UnityEngine;

namespace LokFriends
{
    public sealed class Challenge : MonoBehaviour
    {
        private sealed class Round
        {
            public readonly int Seed;
            public readonly List<int>[] Times = { new List<int>(), new List<int>(), new List<int>() };

            public Round(int seed)
            {
                Seed = seed;
            }
        }

        private const string RoundVersion = "2 ";
        private static Challenge instance;
        private DailyMenu menu;
        private Round round;
        private int slot;
        private bool recorded;
        private Vector2 scroll;
        private FileStream stateLock;
        private bool stateLoaded;
        private float rerollAvailableAt;
        private string storageError;
        private GUIStyle buttonStyle;
        private GUIStyle headingStyle;
        private GUIStyle labelStyle;

        private static string StatePath
        {
            get { return Path.Combine(Application.persistentDataPath, "FriendChallenges.txt"); }
        }

        public static void EnterMenu(DailyMenu dailyMenu)
        {
            if (instance == null)
            {
                var overlay = new GameObject("LOK Friends");
                DontDestroyOnLoad(overlay);
                instance = overlay.AddComponent<Challenge>();
            }

            if (instance.stateLock == null)
                instance.LoadRound();

            instance.menu = dailyMenu;
            instance.slot = 0;
            dailyMenu.dateText.enabled = false;
            dailyMenu.countdownText.enabled = false;
            dailyMenu.hourText.enabled = false;
        }

        public static GenLevel Generate(int slot, bool lok, bool tlak, bool ta, bool be, bool xs)
        {
            int seed = unchecked(instance.round.Seed + 104729 * slot);
            GenLevel level;
            if (slot == 3)
                level = GlassPuzzle.Generate(seed);
            else
            {
                LOKGenerator.SetSeed(seed);
                level = LOKGenerator.GenerateLevel(3, lok, tlak, ta, be, xs);
            }

            instance.slot = slot;
            instance.recorded = false;
            instance.scroll = Vector2.zero;
            return level;
        }

        public static int RecordFinish(int milliseconds)
        {
            if (instance != null && instance.slot != 0 && !instance.recorded)
            {
                instance.recorded = true;
                instance.round.Times[instance.slot - 1].Add(milliseconds);
                instance.SaveRound(instance.round);
            }
            return milliseconds;
        }

        private static Round NewRound()
        {
            return new Round(BitConverter.ToInt32(Guid.NewGuid().ToByteArray(), 0));
        }

        private void LoadRound()
        {
            round = NewRound();
            try
            {
                stateLock = new FileStream(StatePath + ".lock", FileMode.OpenOrCreate,
                    FileAccess.Write, FileShare.None);
                if (!File.Exists(StatePath))
                {
                    stateLoaded = true;
                    SaveRound(round);
                    return;
                }

                string[] lines = File.ReadAllLines(StatePath);
                if (lines.Length != 4)
                    throw new FormatException("A challenge round requires four lines.");

                bool legacy = !lines[0].StartsWith(RoundVersion, StringComparison.Ordinal);
                string seed = legacy ? lines[0] : lines[0].Substring(RoundVersion.Length);
                var saved = new Round(int.Parse(seed, CultureInfo.InvariantCulture));
                // The third grid has changed. Keep its old times in the
                // original record and reconnect only times with the same grid.
                for (int i = 0; i < (legacy ? 2 : saved.Times.Length); i++)
                {
                    if (lines[i + 1].Length == 0)
                        continue;

                    foreach (string value in lines[i + 1].Split(','))
                    {
                        int time = int.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
                        saved.Times[i].Add(time);
                    }
                }
                if (legacy)
                {
                    string backup = StatePath + ".before-glass-update";
                    if (!File.Exists(backup))
                        File.Copy(StatePath, backup);
                }
                round = saved;
                stateLoaded = true;
                if (legacy)
                    SaveRound(round);
            }
            catch (Exception exception)
            {
                storageError = stateLock == null
                    ? "Tempi in uso o non accessibili."
                    : "Impossibile leggere i tempi salvati.";
                Debug.LogException(exception);
            }
        }

        private void OnDestroy()
        {
            if (stateLock != null)
                stateLock.Dispose();
        }

        private bool SaveRound(Round next)
        {
            if (!stateLoaded)
                return false;

            string path = StatePath;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                var lines = new string[4];
                lines[0] = RoundVersion + next.Seed.ToString(CultureInfo.InvariantCulture);
                for (int i = 0; i < next.Times.Length; i++)
                {
                    lines[i + 1] = string.Join(",", next.Times[i].ConvertAll(
                        time => time.ToString(CultureInfo.InvariantCulture)).ToArray());
                }
                File.WriteAllLines(temporary, lines);
                if (File.Exists(path))
                    File.Replace(temporary, path, null);
                else
                    File.Move(temporary, path);
                storageError = null;
                return true;
            }
            catch (Exception exception)
            {
                storageError = "Impossibile salvare i tempi.";
                Debug.LogException(exception);
                return false;
            }
            finally
            {
                try
                {
                    if (File.Exists(temporary))
                        File.Delete(temporary);
                }
                catch (IOException exception)
                {
                    Debug.LogException(exception);
                }
                catch (UnauthorizedAccessException exception)
                {
                    Debug.LogException(exception);
                }
            }
        }

        private void OnGUI()
        {
            var navigation = MainNavigation.instance;
            if (navigation == null || menu == null)
                return;

            var state = navigation.GetState();
            if (state != MainNavigation.State.DAILY && state != MainNavigation.State.DAILY_LEVEL)
                return;

            if (buttonStyle == null)
            {
                buttonStyle = new GUIStyle(GUI.skin.button) { fontSize = 18 };
                headingStyle = new GUIStyle(GUI.skin.label) { fontSize = 16, fontStyle = FontStyle.Bold };
                labelStyle = new GUIStyle(GUI.skin.label) { fontSize = 15, wordWrap = true };
            }

            Matrix4x4 previousMatrix = GUI.matrix;
            float scale = Mathf.Clamp(Screen.height / 720f, 0.7f, 2f);
            GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));
            float width = Screen.width / scale;
            float height = Screen.height / scale;
            if (state == MainNavigation.State.DAILY)
                DrawMenu(width, height);
            else if (slot != 0)
                DrawTimes(width, height);
            GUI.matrix = previousMatrix;
        }

        private void DrawMenu(float width, float height)
        {
            GUI.enabled = stateLoaded && !MainNavigation.instance.dialogOpen &&
                Time.realtimeSinceStartup >= rerollAvailableAt;
            if (GUI.Button(new Rect(width / 2 - 110, height * 0.095f, 220, 40),
                "Rigenera puzzle", buttonStyle))
            {
                Round next = NewRound();
                if (next.Seed == round.Seed)
                    next = new Round(unchecked(round.Seed + 1));
                if (SaveRound(next))
                {
                    round = next;
                    rerollAvailableAt = Time.realtimeSinceStartup + 1;
                    menu.ClickRerollSeed();
                }
            }
            GUI.enabled = true;

            if (storageError != null)
                GUI.Box(new Rect(width / 2 - 175, height * 0.095f + 47, 350, 32), storageError);
        }

        private void DrawTimes(float width, float height)
        {
            List<int> times = round.Times[slot - 1];
            float panelWidth = Mathf.Min(205, width * 0.28f);
            float panelHeight = Mathf.Min(height * 0.28f, 48 + Math.Max(1, times.Count) * 24);
            var panel = new Rect(width - panelWidth - 14, height * 0.22f, panelWidth, panelHeight);
            Color previousColor = GUI.color;
            GUI.color = new Color(0.62f, 0.62f, 0.62f);
            GUI.Box(panel, GUIContent.none);
            GUI.color = previousColor;
            GUILayout.BeginArea(new Rect(panel.x + 9, panel.y + 5, panel.width - 18, panel.height - 10));
            GUILayout.Label("Tempi del puzzle " + slot, headingStyle);
            if (times.Count == 0)
                GUILayout.Label("Nessun tempo registrato", labelStyle);
            else
            {
                scroll = GUILayout.BeginScrollView(scroll);
                for (int i = 0; i < times.Count; i++)
                {
                    TimeSpan elapsed = TimeSpan.FromMilliseconds(times[i]);
                    string formatted = string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}.{2:000}",
                        (int)elapsed.TotalMinutes, elapsed.Seconds, elapsed.Milliseconds);
                    GUILayout.Label((i + 1) + ".  " + formatted, labelStyle);
                }
                GUILayout.EndScrollView();
            }
            GUILayout.EndArea();

            if (storageError != null)
                GUI.Box(new Rect(panel.x, panel.yMax + 4, panel.width, 28), storageError);
        }
    }
}
