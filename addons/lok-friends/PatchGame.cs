using System;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class PatchGame
{
    private static MethodDefinition Method(ModuleDefinition module, string type, string name)
    {
        return module.GetType(type).Methods.Single(method => method.Name == name);
    }

    private static Instruction CallTo(MethodDefinition method, string type, string name)
    {
        return method.Body.Instructions.Single(instruction =>
        {
            var target = instruction.Operand as MethodReference;
            return (instruction.OpCode == OpCodes.Call || instruction.OpCode == OpCodes.Callvirt) &&
                target != null && target.DeclaringType.Name == type && target.Name == name;
        });
    }

    private static MethodReference Hook(ModuleDefinition game, TypeDefinition hooks, string name,
        TypeReference result, params TypeReference[] parameters)
    {
        var reference = new MethodReference(name, result, game.ImportReference(hooks));
        foreach (TypeReference parameter in parameters)
            reference.Parameters.Add(new ParameterDefinition(parameter));
        return reference;
    }

    private static void ReplaceWithReturn(MethodDefinition method, bool returnZero)
    {
        method.Body = new MethodBody(method);
        ILProcessor il = method.Body.GetILProcessor();
        if (returnZero)
            il.Emit(OpCodes.Ldc_I4_0);
        il.Emit(OpCodes.Ret);
    }

    private static void DiscardCall(MethodDefinition method, string type, string name)
    {
        Instruction instruction = CallTo(method, type, name);
        var target = (MethodReference)instruction.Operand;
        if (target.ReturnType.MetadataType != MetadataType.Void || !target.HasThis)
            throw new InvalidOperationException("Expected a void instance call: " + target.FullName);

        ILProcessor il = method.Body.GetILProcessor();
        instruction.OpCode = OpCodes.Pop;
        instruction.Operand = null;
        foreach (ParameterDefinition parameter in target.Parameters)
        {
            Instruction pop = il.Create(OpCodes.Pop);
            il.InsertAfter(instruction, pop);
            instruction = pop;
        }
    }

    private static void PatchGlassGenerator(ModuleDefinition game, TypeDefinition hooks)
    {
        MethodDefinition generate = Method(game, "LOKGenerator", "GenerateLevel");
        Instruction cycleStore = generate.Body.Instructions.Single(i => i.Offset == 79 &&
            i.OpCode == OpCodes.Stsfld && ((FieldReference)i.Operand).Name == "cycles");
        generate.Body.GetILProcessor().InsertBefore(cycleStore, Instruction.Create(OpCodes.Call,
            Hook(game, hooks, "SelectCycles", game.TypeSystem.Int32, game.TypeSystem.Int32)));

        MethodDefinition step = Method(game, "LOKGenerator", "AddSolveStep");
        ILProcessor stepIl = step.Body.GetILProcessor();
        stepIl.InsertBefore(step.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0));
        stepIl.InsertAfter(step.Body.Instructions[0], Instruction.Create(OpCodes.Call,
            Hook(game, hooks, "GuardStep", game.TypeSystem.Void, game.TypeSystem.Int32)));
        Instruction choose = CallTo(step, "Random", "Range");
        FieldDefinition words = step.DeclaringType.Fields.Single(field => field.Name == "validWords");
        stepIl.InsertBefore(choose, Instruction.Create(OpCodes.Ldarg_0));
        stepIl.InsertBefore(choose, Instruction.Create(OpCodes.Ldsfld, words));
        choose.Operand = Hook(game, hooks, "SelectWord", game.TypeSystem.Int32,
            game.TypeSystem.Int32, game.TypeSystem.Int32, game.TypeSystem.Int32, words.FieldType);

        MethodDefinition ta = Method(game, "LOKGenerator", "AddTA");
        Instruction targetCount = ta.Body.Instructions.Single(i => i.Offset == 342 &&
            i.OpCode == OpCodes.Call && ((MethodReference)i.Operand).Name == "Range");
        targetCount.Operand = Hook(game, hooks, "SelectTargetCount", game.TypeSystem.Int32,
            game.TypeSystem.Int32, game.TypeSystem.Int32);

        foreach (string name in new[] { "AddTA", "AddTLAK", "AddLOK" })
        {
            MethodDefinition placement = Method(game, "LOKGenerator", name);
            Instruction pivot = CallTo(placement, "GenLevelBoard", "GetRandomBlackTilePos");
            var originalPivot = (MethodReference)pivot.Operand;
            pivot.OpCode = OpCodes.Call;
            pivot.Operand = Hook(game, hooks, "SelectPivot", originalPivot.ReturnType,
                originalPivot.DeclaringType, game.TypeSystem.Int32);

            Instruction[] targets = placement.Body.Instructions.Where(i =>
            {
                var target = i.Operand as MethodReference;
                return i.OpCode == OpCodes.Callvirt && target != null &&
                    target.DeclaringType.Name == "GenLevelBoard" && target.Name == "AddTile";
            }).ToArray();
            if (targets.Length != (name == "AddTLAK" ? 2 : 1))
                throw new InvalidOperationException("Unexpected number of target placements in " + name);
            ILProcessor il = placement.Body.GetILProcessor();
            for (int ordinal = 0; ordinal < targets.Length; ordinal++)
            {
                Instruction target = targets[ordinal];
                var original = (MethodReference)target.Operand;
                TypeReference[] parameters = new[] { original.DeclaringType }
                    .Concat(original.Parameters.Select(parameter => parameter.ParameterType))
                    .Concat(new[] { game.TypeSystem.Int32 }).ToArray();
                il.InsertBefore(target, Instruction.Create(OpCodes.Ldc_I4, ordinal));
                target.OpCode = OpCodes.Call;
                target.Operand = Hook(game, hooks, "PlaceTarget", original.ReturnType, parameters);
            }
        }
    }

    private static int Main(string[] args)
    {
        if (args.Length != 3)
            throw new ArgumentException("Expected original game assembly, challenge assembly and output path.");

        using (var resolver = new DefaultAssemblyResolver())
        {
            resolver.AddSearchDirectory(Path.GetDirectoryName(args[0]));
            return Run(args, resolver);
        }
    }

    private static int Run(string[] args, IAssemblyResolver resolver)
    {
        var reader = new ReaderParameters { AssemblyResolver = resolver };
        using (var original = AssemblyDefinition.ReadAssembly(args[0], reader))
        using (var plugin = AssemblyDefinition.ReadAssembly(args[1], reader))
        {
            ModuleDefinition game = original.MainModule;
            TypeDefinition hooks = plugin.MainModule.GetType("LokFriends.Challenge");
            PatchGlassGenerator(game, plugin.MainModule.GetType("LokFriends.GlassPuzzle"));

            MethodDefinition visit = Method(game, "DailyMenu", "Visit");
            ILProcessor visitIl = visit.Body.GetILProcessor();
            Instruction last = visit.Body.Instructions.Single(i => i.OpCode == OpCodes.Ret);
            last.OpCode = OpCodes.Ldarg_0;
            Instruction attach = visitIl.Create(OpCodes.Call, Hook(game, hooks, "EnterMenu",
                game.TypeSystem.Void, visit.DeclaringType));
            visitIl.InsertAfter(last, attach);
            visitIl.InsertAfter(attach, visitIl.Create(OpCodes.Ret));

            MethodDefinition setup = Method(game, "DailyGrid", "SetupRandom");
            Instruction generate = CallTo(setup, "LOKGenerator", "GenerateLevel");
            var stockGenerator = (MethodReference)generate.Operand;
            generate.Operand = Hook(game, hooks, "Generate", stockGenerator.ReturnType,
                stockGenerator.Parameters.Select(parameter => parameter.ParameterType).ToArray());

            MethodDefinition complete = Method(game, "WorldLevelManager", "OnCompleteLevel");
            Instruction timer = CallTo(complete, "DailyLevelUI", "GetTimeMillis");
            ILProcessor completeIl = complete.Body.GetILProcessor();
            completeIl.InsertAfter(timer, completeIl.Create(OpCodes.Call,
                Hook(game, hooks, "RecordFinish", game.TypeSystem.Int32, game.TypeSystem.Int32)));
            // The daily completion writes only the challenge record. Leave the
            // campaign branch of OnCompleteLevel intact.
            Instruction dailySave = complete.Body.Instructions
                .SkipWhile(instruction => instruction != timer)
                .First(instruction =>
                {
                    var target = instruction.Operand as MethodReference;
                    return target != null && target.Name == "saveCurrentGameDataIntoJson";
                });
            dailySave.OpCode = OpCodes.Pop;
            dailySave.Operand = null;
            DiscardCall(complete, "LeaderboardManager", "UpdateLeaderboardByName");
            DiscardCall(complete, "AchievementManager", "UnlockAchievementByName");

            ReplaceWithReturn(Method(game, "DailiesData", "isDailyLevelCompleted"), true);
            ReplaceWithReturn(Method(game, "DailiesData", "getDailyLevelMillis"), true);
            ReplaceWithReturn(Method(game, "DailiesData", "setDailyLevelCompleted"), false);
            ReplaceWithReturn(Method(game, "DailiesData", "setDailyLevelPlayed"), false);
            ReplaceWithReturn(Method(game, "PersistenceSystem", "saveDailiesIntoJson"), false);

            MethodDefinition settings = Method(game, "PersistenceSystem", ".cctor");
            Instruction leaderboardFlag = settings.Body.Instructions.Single(instruction =>
            {
                var field = instruction.Operand as FieldReference;
                return instruction.OpCode == OpCodes.Stsfld && field != null && field.Name == "LEADERBOARD_ON";
            });
            if (leaderboardFlag.Previous.OpCode != OpCodes.Ldc_I4_1)
                throw new InvalidOperationException("Unexpected leaderboard initialization.");
            leaderboardFlag.Previous.OpCode = OpCodes.Ldc_I4_0;

            original.Write(args[2]);
        }
        return 0;
    }
}
