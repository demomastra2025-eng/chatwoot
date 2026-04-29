"""Native OneLink Weixin Personal gateway skeleton.

This package intentionally has no dependency on external agent runtimes. It keeps
only the protocol boundary that OneLink Rails calls over the internal gateway API.
"""

__all__ = [
    "callbacks",
    "config",
    "ilink",
    "models",
    "registry",
    "security",
]
