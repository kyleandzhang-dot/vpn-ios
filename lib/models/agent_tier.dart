class AgentTier {
  final String name;
  final int price;
  final int wholesale;

  const AgentTier({
    required this.name,
    required this.price,
    required this.wholesale,
  });

  int get commission => price - wholesale; // 自动计算利润
}

const List<AgentTier> kAgentTiers = [
  AgentTier(name: "月卡", price: 29, wholesale: 19),
  AgentTier(name: "年卡", price: 99, wholesale: 69),
  AgentTier(name: "终身卡", price: 198, wholesale: 158),
];