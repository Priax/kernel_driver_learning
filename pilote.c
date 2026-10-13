// SPDX-License-Identifier: GPL-2.0
#include <linux/completion.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/printk.h>

#define EDU_BAR 0
// Valeurs déduite via le log "edu détecté: 0000:00:04.0", puis lspci -nn
#define EDU_VENDOR_ID 0x1234
#define EDU_DEVICE_ID 0x11e8

#define EDU_REG_ID 0x00
#define EDU_ID_VALUE 0x010000ed

#define EDU_REG_LIVENESS 0x04 // It is a simple value inversion (~ C operator).

#define EDU_REG_FACT 0x08 // write n, get n!

#define EDU_REG_STATUS 0x20
#define EDU_STATUS_IRQ_FACT 0x80

// It contains values which raised the interrupt (see interrupt raise register below).
#define EDU_REG_IRQ_STATUS 0x24
#define EDU_IRQ_FACT 0x01
#define EDU_IRQ_DMA 0x100

// Clear an interrupt. The value will be cleared from the interrupt status register. (EDU_IRQ_STATUS)
// This needs to be done from the ISR to stop generating interrupts.
#define EDU_REG_IRQ_ACK 0x64

#define EDU_REG_DMA_SRC 0x80 // Where to perform the DMA from.
#define EDU_REG_DMA_DST 0x88 // Where to perform the DMA to.
#define EDU_REG_DMA_CNT 0x90 // The size of the area to perform the DMA on.
#define EDU_REG_DMA_CMD 0x98
// Bitwise OR of:
// - 0x01: start transfer
// - 0x02: direction (0: from RAM to EDU, 1: from EDU to RAM)
// - 0x04: raise interrupt 0x100 after finishing the DMA
#define EDU_DMA_START 0x01
#define EDU_DMA_TO_RAM 0x02
#define EDU_DMA_IRQ 0x04

#define EDU_DMA_BUF 0x40000

// On déclare quel matériel ce pilote gère
static const struct pci_device_id edu_pci_ids[] = {
	{ PCI_DEVICE(EDU_VENDOR_ID, EDU_DEVICE_ID) },
	{ 0 } // La liste doit toujours se terminer par des zéros
};

// Pour que des outils comme udev puissent charger le module automatiquement
MODULE_DEVICE_TABLE(pci, edu_pci_ids);

struct edu_dev {
	void __iomem *mmio;

	struct completion dma_done;

	// Variables pour le DMA
	void *vaddr_from; // Adresse virtuelle (pour le processeur)
	dma_addr_t dma_handle_from; // Adresse physique (pour la carte PCI)

	void *vaddr_to;
	dma_addr_t dma_handle_to;
};

// Le gestionnaire d'interruption (IRQ Handler)
// Cette fonction s'exécute TOUTE SEULE quand la carte a fini.
static irqreturn_t edu_irq_handler(int irq, void *dev_id)
{
	u32 status, result;
	struct edu_dev *edu = dev_id;

	// Pourquoi avons-nous été interrompus ?
	status = ioread32(edu->mmio + EDU_REG_IRQ_STATUS);

	if (!(status & (EDU_IRQ_FACT | EDU_IRQ_DMA))) {
		// Ce n'est pas le signal de fin de factorielle ou de fin DMA.
		// (Les lignes IRQ sont souvent partagées avec d'autres cartes)
		return IRQ_NONE;
	}

	// Lire le résultat de la factorielle
	if (status & EDU_IRQ_FACT) {
		result = ioread32(edu->mmio + EDU_REG_FACT);
		pr_alert("EDU IRQ: Résultat de la factorielle = %u\n", result);
	}

	// Donner le signal que le transfert de donnée DMA est fini.
	if (status & EDU_IRQ_DMA)
		complete(&edu->dma_done);

	// Acquitter (éteindre) l'interruption
	iowrite32(status, edu->mmio + EDU_REG_IRQ_ACK);

	return IRQ_HANDLED; // On dit au noyau qu'on a bien géré le signal
}

static int edu_dma(struct edu_dev *edu, dma_addr_t src, dma_addr_t dst,
		   u32 count, u32 cmd)
{
	reinit_completion(&edu->dma_done);
	// Registre de 64 bits, partie haute nul grâce au dma_set_mask
	iowrite32(lower_32_bits(src), edu->mmio + EDU_REG_DMA_SRC);
	iowrite32(lower_32_bits(dst), edu->mmio + EDU_REG_DMA_DST);

	iowrite32(count, edu->mmio + EDU_REG_DMA_CNT);
	// Lance le transfert (sens et IRQ fixés par cmd)
	iowrite32(cmd, edu->mmio + EDU_REG_DMA_CMD);
	if (!wait_for_completion_timeout(&edu->dma_done,
					 msecs_to_jiffies(1000)))
		return -ETIMEDOUT;

	return 0;
}

static int edu_probe(struct pci_dev *dev, const struct pci_device_id *id)
{
	u32 magic_value;
	u32 test_val = 0x00000043;
	u32 inverted_val;
	int err;
	struct edu_dev *edu;

	pr_alert("Périphérique QEMU EDU détecté !\n");

	edu = devm_kzalloc(&dev->dev, sizeof(*edu), GFP_KERNEL);
	if (!edu)
		return -ENOMEM;

	init_completion(&edu->dma_done);
	pci_set_drvdata(dev, edu);

	// Activation du périphérique (réveille le matériel et lui alloue ses
	// ressources)
	err = pci_enable_device(dev);
	if (err) {
		pr_err("Erreur lors de l'activation du périphérique PCI\n");
		return err;
	}

	// Autoriser la carte à faire du DMA (Bus Mastering)
	pci_set_master(dev);

	err = dma_set_mask_and_coherent(&dev->dev, DMA_BIT_MASK(28));
	if (err)
		goto err_alloc_from;

	// Allocation de 4096 octets (4 Ko) en RAM pour la source
	edu->vaddr_from = dma_alloc_coherent(&dev->dev, 4096,
					     &edu->dma_handle_from, GFP_KERNEL);
	if (!edu->vaddr_from) {
		err = -ENOMEM;
		goto err_alloc_from;
	}

	// Allocation de 4096 octets pour la destination
	edu->vaddr_to = dma_alloc_coherent(&dev->dev, 4096, &edu->dma_handle_to,
					   GFP_KERNEL);
	if (!edu->vaddr_to) {
		err = -ENOMEM;
		goto err_alloc_to;
	}

	pr_info("EDU DMA: vaddr_from = %p, dma_handle_from = %llx\n",
		edu->vaddr_from, (unsigned long long)edu->dma_handle_from);
	pr_info("EDU DMA: vaddr_to = %p, dma_handle_to = %llx\n", edu->vaddr_to,
		(unsigned long long)edu->dma_handle_to);

	// Réservation exclusive de toutes les adresses (BARs) de la carte
	err = pci_request_regions(dev, "qemu_edu_driver");
	if (err)
		goto err_regions;

	// Mapping virtuel du BAR 0 (qui contient les registres de la carte EDU)
	// Le 0 correspond au numéro du BAR (BAR 0), le deuxième 0 indique qu'on
	// mappe toute sa taille
	edu->mmio = pci_iomap(dev, EDU_BAR, 0);
	if (!edu->mmio) {
		err = -ENOMEM;
		goto err_iomap;
	}

	// On s'abonne à la ligne d'interruption (dev->irq)
	// IRQF_SHARED indique qu'on accepte de partager cette ligne avec d'autres
	// périphériques
	err = request_irq(dev->irq, edu_irq_handler, IRQF_SHARED,
			  "qemu_edu_driver", edu);
	if (err) {
		pr_err("EDU: Impossible de demander l'IRQ %d\n", dev->irq);
		goto err_irq;
	}

	// On lit 32 bits à l'offset 0 de notre pointeur virtuel
	magic_value = ioread32(edu->mmio + EDU_REG_ID);
	if (magic_value != EDU_ID_VALUE) {
		err = -ENODEV;
		goto err_magic;
	}
	pr_alert("EDU: Valeur magique lue = 0x%08x\n", magic_value);

	// ÉCRITURE DANS LA MÉMOIRE (Test d'inversion matérielle)
	pr_info("EDU: Envoi de la valeur 0x%08x à la carte...\n", test_val);

	// On écrit à l'offset 0x04
	iowrite32(test_val, edu->mmio + EDU_REG_LIVENESS);

	// On relit immédiatement à ce même offset
	inverted_val = ioread32(edu->mmio + EDU_REG_LIVENESS);

	pr_alert("EDU: La carte a répondu avec l'inversion : 0x%08x\n",
		 inverted_val);

	// Vérification mathématique (~ est l'opérateur C pour le NOT bit à bit)
	if (inverted_val == ~test_val)
		pr_alert("EDU: Le calcul matériel est correct !\n");

	pr_alert("EDU: Armement de l'alarme IRQ pour la factorielle...\n");
	// On met le bit 7 à '1' dans le registre d'état (0x20) sinon le calcul se
	// lance silencieusement et ne renvoie rien
	iowrite32(EDU_STATUS_IRQ_FACT, edu->mmio + EDU_REG_STATUS);

	pr_alert("EDU: Lancement du calcul de 10!...\n");
	// Le processeur écrit 10 puis continue sa vie. L'interruption fera le reste
	iowrite32(10, edu->mmio + EDU_REG_FACT);

	// LE GRAND FINAL : TRANSFERT DMA
	// On écrit un message secret dans la RAM source (vaddr_from)
	snprintf((char *)edu->vaddr_from, 4096, "Hellooooo !!!!!");

	// On vérifie que la destination est bien vide
	pr_alert("EDU DMA: Dest AVANT le transfert = '%s'\n",
		 (char *)edu->vaddr_to);

	err = edu_dma(edu, edu->dma_handle_from, EDU_DMA_BUF, 4096,
		      EDU_DMA_START | EDU_DMA_IRQ); /* RAM → EDU */
	if (err)
		goto err_magic;

	err = edu_dma(edu, EDU_DMA_BUF, edu->dma_handle_to, 4096,
		      EDU_DMA_START | EDU_DMA_TO_RAM |
			      EDU_DMA_IRQ); /* EDU → RAM */
	if (err)
		goto err_magic;

	// LE MOMENT DE VÉRITÉ
	pr_alert("EDU DMA: Dest APRÈS le transfert = '%s'\n",
		 (char *)edu->vaddr_to);

	return 0; // Retourner 0 signifie que l'initialisation a réussi
err_magic:
	free_irq(dev->irq, edu);
err_irq:
	pci_iounmap(dev, edu->mmio);
err_iomap:
	pci_release_regions(dev);
err_regions:
	dma_free_coherent(&dev->dev, 4096, edu->vaddr_to, edu->dma_handle_to);
err_alloc_to:
	dma_free_coherent(&dev->dev, 4096, edu->vaddr_from,
			  edu->dma_handle_from);
err_alloc_from:
	pci_disable_device(dev);
	return err;
}

static void edu_remove(struct pci_dev *dev)
{
	// On détruit tout, EXACTEMENT dans l'ordre inverse de la création
	struct edu_dev *edu = pci_get_drvdata(dev);

	pr_alert("Désactivation du périphérique QEMU EDU.\n");

	free_irq(dev->irq, edu);
	pci_iounmap(dev, edu->mmio); // Détruit le pointeur virtuel
	pci_release_regions(dev); // Retire le panneau "Propriété privée"
	dma_free_coherent(&dev->dev, 4096, edu->vaddr_to, edu->dma_handle_to);
	dma_free_coherent(&dev->dev, 4096, edu->vaddr_from,
			  edu->dma_handle_from);
	pci_disable_device(dev); // Rendort la carte
}

// Structure regroupant nos fonctions pour le noyau
static struct pci_driver edu_driver = {
	.name = "qemu_edu_driver",
	.id_table = edu_pci_ids,
	.probe = edu_probe,
	.remove = edu_remove,
};

static int __init edu_init(void)
{
	pr_info("Enregistrement du pilote PCI EDU...\n");
	return pci_register_driver(&edu_driver);
}

static void __exit edu_exit(void)
{
	pr_info("Désenregistrement du pilote PCI EDU...\n");
	pci_unregister_driver(&edu_driver);
}

module_init(edu_init);
module_exit(edu_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Priax");
MODULE_DESCRIPTION("A very descriptive description");
