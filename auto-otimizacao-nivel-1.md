# Auto-Otimização - Nível 1: Padrão de Verificação (verification-standard.md)

# verification-standard.md - what "correct" means for this work
# [deterministic, re-runnable, read-only while an output is being fixed]

## Acceptance criteria (pass/fail, never scores)
- [Define the checks an output MUST pass. Concrete, objective, observable.]
- [Each criterion is repeatable and judged pass/fail - no 0-5 ratings.]

## How to run the check
- [The exact procedure to evaluate an output against every criterion above.]
- [Where possible, a second reviewer with a CLEAN context runs it - unbiased by the maker.]

## Baseline
- [The last approved output (s) to compare against - flag any regression from it.]

## Output of a check run
- PASS/FAIL per criterion
- On FAIL: attach the evidence + a description of the defect to learnings, then trigger the fix loop