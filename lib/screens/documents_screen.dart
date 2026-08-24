import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DocumentsScreen extends StatefulWidget {
  // 1. حولته ل Stateful عشان uid
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final String uid =
      FirebaseAuth.instance.currentUser!.uid; // 2. شلته من الـ const

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("التحقق والوثائق"),
        backgroundColor: Colors.orange,
        centerTitle: true,
      ),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance
            .collection('captains')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            );
          }
          if (snap.hasError) {
            return const Center(child: Text("حدث خطأ"));
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: Text("لا توجد بيانات"));
          }

          var data = snap.data!.data()!;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _docItem(
                "رخصة القيادة",
                data['licenseStatus'] ?? 'pending',
                data['licenseUrl'],
              ),
              const SizedBox(height: 12),
              _docItem("الهوية", data['idStatus'] ?? 'pending', data['idUrl']),
              const SizedBox(height: 12),
              _docItem(
                "صورة السيارة",
                data['carStatus'] ?? 'pending',
                data['carUrl'],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _docItem(String title, String status, String? url) {
    Color statusColor;
    String statusText;

    if (status == 'approved') {
      // 3. حطيت {} عشان خطأ الـ if
      statusColor = Colors.green;
      statusText = 'مفعلة';
    } else if (status == 'rejected') {
      statusColor = Colors.red;
      statusText = 'مرفوضة';
    } else {
      statusColor = Colors.orange;
      statusText = 'قيد المراجعة';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.description, color: Colors.orange, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
              ],
            ),
          ),
          if (url != null) // 4. شلت الـ string interpolation الغير ضرورية
            IconButton(
              icon: const Icon(Icons.visibility, color: Colors.grey),
              onPressed: () {},
            ),
        ],
      ),
    );
  }
}
