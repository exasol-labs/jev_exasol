import asyncio

from dotenv import load_dotenv
from typesafe_sdk import AsyncTypeSafeClient, Choice, Noul, Score


async def main() -> None:
    """Test the TypeSafe client SDK outside of the Exasol before integrating it in Exasol to see if the API is working as expected."""

    load_dotenv()

    async with AsyncTypeSafeClient() as client:
        response = await client.system_one(
            state={"document": "I was charged twice. Please fix this ASAP."},
            questions={
                "billing": Noul(instructions="Is this ticket about billing?"),
                "tone": Choice(
                    instructions="What is the customer's tone?",
                    criteria={"calm": None, "frustrated": None, "angry": None},
                ),
                "urgency": Score(
                    instructions="How urgent is this ticket?",
                    criteria=["can wait", "this week", "today"],
                ),

            },
        )

    print(f"model      {response.model}")
    print(f"request_id {response.request_id}")
    print(f"usage      in={response.usage.input_tokens} out={response.usage.output_tokens}")

    billing = response.nouls["billing"]
    print(f"\nbilling (noul)   p(yes)={billing.noul:.3f}")

    tone = response.choices["tone"]
    print(f"\ntone (choice)    {tone.choice}  confidence={tone.confidence:.3f}")
    for name, p in sorted(tone.probabilities.items(), key=lambda kv: -kv[1]):
        print(f"    {name:<12} {p:.3f}")

    urgency = response.scores["urgency"]
    print(f"\nurgency (score)  {urgency.score:.3f}  confidence={urgency.confidence:.3f}")
    for level, p in sorted(urgency.probabilities.items()):
        print(f"    {level}  {str(urgency.legend[level]):<12} {p:.3f}")


if __name__ == "__main__":
    asyncio.run(main())
