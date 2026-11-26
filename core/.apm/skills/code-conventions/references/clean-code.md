# Clean code rules for every language

We use Robert C. Martin's *Clean Code* in a practical way, not as a whole. No analyzer checks these
rules well, so the plan, the build and the review check them, not the build tools. The analyzer rules
of one language live in the convention skill of that language, such as the clean code page of
`csharp-generation-smells` in the dotnet pack.

## Reuse before you build

Before you add an interface, service, controller, model, helper, script or test double, search for one
that already owns the idea. Then take the first that fits:

1. **Reuse** what exists: a service, a helper, a test double, a test class.
2. **Extend** it: add a member, a test method or a parameter to what exists.
3. **Write new code** in the style of the nearest example, only when neither fits.

Never copy a class to change it a little. Do not build a second reader next to a service that already
gives the data, or a second controller for a resource another one owns. Put a new type in the layer
that owns the idea. When a search finds nothing, name what you searched.

## Build only what the story needs

Build only what the acceptance criteria of the story need. No options, parameters, concurrency tokens
or endpoints "in case we need them". An unused parameter or an option no caller sets is dead weight;
leave it out until a real need comes.

## Rules for the shape of the code

- **A function does one thing**, at one level of abstraction.
- **Command-query separation.** A method either does something or answers something, not both. A
  function that gets data returns it and writes nothing to the console; it leaves the report of a
  failure to its caller. In PowerShell, SonarCloud checks this for a `Get-*` function as
  `powershelldre:S8677`: keep the reason in a script-scoped variable, or rename the function.
- **Behaviour on the types, not a type switch.** Map a closed set to a value with a switch, but put
  behaviour on the types instead of branching on a type code.
- **Wrap conditions in a name.** Put a boolean expression that is not obvious behind a member with a
  clear name.
- **Repeat nothing that is really the same**, but do not merge "just in case". The analyzers catch the
  same bodies and the same literals; repeated ideas are a judgement call.
- **Small classes** that hold together and have few reasons to change.
- **Names that show intent.** A tool checks the casing, not whether a name is good.

## The platform is a set of machines

State that a gate or another process reads must describe every instance and every slot, not the one
that answered. Check the worker count; do not assume one.

## Related

- [The code-conventions skill](../SKILL.md) - the short form of these rules and the other shared rules.
- [Skills by file type](skills-by-file-type.md) - the language skill that adds the analyzer rules of each file type.
- [Code comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 in full.
