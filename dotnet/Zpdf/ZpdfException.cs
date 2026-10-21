using System;

namespace Zpdf;

/// <summary>A zpdf call failed.</summary>
/// <remarks>
/// <see cref="ErrorName"/> is zpdf's name for the failure, such as <c>Malformed</c>,
/// <c>PasswordRequired</c>, <c>UnsupportedFilter</c> or <c>InvalidPage</c>; <see cref="Code"/> is its
/// number in zpdf's C ABI.
/// </remarks>
public sealed class ZpdfException : Exception
{
    public ZpdfException(int code, string errorName)
        : base($"zpdf: {errorName}")
    {
        Code = code;
        ErrorName = errorName;
    }

    public int Code { get; }

    public string ErrorName { get; }
}
