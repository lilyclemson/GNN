import python3 as python;

STRING testVersion := EMBED(python)
    import sys
    return sys.version
ENDEMBED;

OUTPUT(testVersion);