def register(registry):
    registry.add_prompt_addendum("prep", "PARTIAL-MUST-NOT-APPEAR")
    registry.add_private_project("Partial-Project")
    raise RuntimeError("boom in register")
